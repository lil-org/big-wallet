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

function bundle(entryPoint, format = "cjs", contents) {
    return buildSync({
        bundle: true,
        ...(contents ? {
            stdin: {
                contents,
                resolveDir: fileURLToPath(providerDirectory),
                sourcefile: entryPoint,
            },
        } : {
            entryPoints: [fileURLToPath(new URL(entryPoint, providerDirectory))],
        }),
        format,
        logLevel: "silent",
        platform: "browser",
        target: "safari15",
        write: false,
    }).outputFiles[0].text;
}

const operationRuntimeSource = bundle("operation_runtime.js");
const rpcSource = bundle("rpc.js");
const ethereumSource = bundle("ethereum-harness.js", "cjs", `
    export {default, applyDecodedEnvelope, subscribeNotifications, withReadyState} from "./ethereum";
    export {createStableFacadeRecord} from "./stable_facades";
`);
const solanaSource = bundle("solana-harness.js", "cjs", `
    export {default, applyDecodedEnvelope, subscribeNotifications} from "./solana";
    export {createStableFacadeRecord} from "./stable_facades";
`);
const base58Source = bundle("base58.js");
const solanaSDKSource = bundle("solana-sdk-harness.js", "cjs", `
    export {
        Keypair, PublicKey, Transaction, TransactionInstruction,
        TransactionMessage, VersionedTransaction,
    } from "@solana/web3.js";
`);
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
        runNextTimer() {
            const callback = timers.shift();
            if (!callback) { return false; }
            callback();
            return true;
        },
        runTimers() {
            while (timers.length > 0) { timers.shift()(); }
        },
    };
}

const solanaSDK = moduleHarness(solanaSDKSource, {TextDecoder, TextEncoder, Uint8Array}).exports;

function normalized(value) {
    return JSON.parse(JSON.stringify(value));
}

function decodedDelivery(envelope) {
    return Object.freeze({__proto__: null, ...envelope});
}

function ethereumHarness(initialState = null) {
    const module = moduleHarness(ethereumSource);
    const requests = [];
    const rpc = [];
    const disconnects = [];
    let current = true;
    let rpcObserver = null;
    let requestObserver = null;
    const transport = Object.freeze({
        isCurrent() { return current; },
        postDisconnect(message) {
            disconnects.push(message);
            return current;
        },
        postRequest(message) {
            requests.push(message);
            requestObserver?.(message);
            return current;
        },
        postRPC(message, generation) {
            rpc.push({generation, message});
            rpcObserver?.(message, generation);
            return current;
        },
    });
    const Ethereum = module.exports.default;
    const engine = new Ethereum("ethereum-generation", transport, initialState);
    const record = module.exports.createStableFacadeRecord({
        uuid: "00000000-0000-4000-8000-000000000001",
    });
    record.prepareTargets({
        ethereumProvider: {
            provider: engine,
            subscribeNotifications: listener => module.exports.subscribeNotifications(
                engine,
                listener
            ),
            withReadyState: listener => module.exports.withReadyState(
                engine,
                listener
            ),
            retire: error => Ethereum.retire(engine, error),
            snapshot: () => Ethereum.snapshot(engine),
        },
        solanaProvider: {
            provider: {accountState: () => null},
            subscribeNotifications: () => () => {},
        },
    }).commit();
    return {
        ...module,
        disconnects,
        applyDecodedEnvelope: envelope => module.exports.applyDecodedEnvelope(engine, decodedDelivery({
            ...envelope,
            ...(envelope.kind === "configuration" ? {
                workerRevision: envelope.workerRevision ?? (Ethereum.snapshot(engine).workerRevision ?? -1) + 1,
            } : {}),
        })),
        snapshot: () => Ethereum.snapshot(engine),
        retire: error => Ethereum.retire(engine, error),
        isReady: () => Ethereum.isReady(engine),
        provider: record.ethereum,
        requests,
        rpc,
        setCurrent(value) { current = value; },
        setRPCObserver(value) { rpcObserver = value; },
        setRequestObserver(value) { requestObserver = value; },
    };
}

function solanaHarness(initialState = null, extraGlobals = {}) {
    const module = moduleHarness(solanaSource, extraGlobals);
    const requests = [];
    const disconnects = [];
    let current = true;
    let currentError = null;
    let disconnectPost = true;
    let requestPost = true;
    let requestObserver = null;
    const transport = Object.freeze({
        isCurrent() {
            if (currentError) { throw currentError; }
            return current;
        },
        postDisconnect(message) {
            disconnects.push(message);
            return current && disconnectPost;
        },
        postRequest(message) {
            requestObserver?.(message);
            requests.push(message);
            return current && requestPost;
        },
    });
    const Solana = module.exports.default;
    const provider = new Solana("solana-generation", transport, initialState);
    const record = module.exports.createStableFacadeRecord({
        uuid: "00000000-0000-4000-8000-000000000002",
    });
    const target = {
        provider,
        subscribeNotifications: listener => module.exports.subscribeNotifications(provider, listener),
    };
    record.prepareTargets({
        ethereumProvider: {
            provider: {},
            subscribeNotifications: () => () => {},
            withReadyState: () => false,
        },
        solanaProvider: target,
    }).commit();
    return {
        applyDecodedEnvelope: (provider, envelope, configurationIsCurrent) => module.exports.applyDecodedEnvelope(
            provider, decodedDelivery(envelope), configurationIsCurrent
        ),
        standardProvider: record.solana,
        target,
        wallet: record.wallet,
        ...module,
        disconnects,
        provider,
        requests,
        setCurrent(value) { current = value; },
        setCurrentError(value) { currentError = value; },
        setDisconnectPost(value) { disconnectPost = value; },
        setRequestPost(value) { requestPost = value; },
        setRequestObserver(value) { requestObserver = value; },
        Solana,
    };
}

function applyEthereumConfiguration(harness, address = "", chainId = "0x1") {
    return harness.applyDecodedEnvelope({
        kind: "configuration",
        configuration: {address, chainId},
    });
}

const firstSolanaKey = "11111111111111111111111111111111";
const secondSolanaKey = "So11111111111111111111111111111111111111112";
const validSignature = "1".repeat(64);

function applySolanaConfiguration(harness, {
    workerRevision = (harness.Solana.snapshot(harness.provider).workerRevision ?? -1) + 1,
    publicKey = null,
} = {}) {
    return harness.applyDecodedEnvelope(harness.provider, decodedDelivery({
        kind: "configuration", configuration: publicKey === null ? null : {publicKey}, workerRevision,
    }));
}

function grantEthereum(harness, id, address, chainId = harness.provider.chainId) {
    applyEthereumConfiguration(harness, address, chainId);
    const state = {revisions: {ethereum: harness.snapshot().workerRevision, solana: 0},
        ethereum: {address, chainId}, solana: null};
    harness.applyDecodedEnvelope({id, name: "requestAccounts", kind: "result", result: address ? [address] : [], state});
}

function grantSolana(harness, id, publicKey) {
    applySolanaConfiguration(harness, {publicKey});
    const state = {revisions: {ethereum: 0, solana: harness.Solana.snapshot(harness.provider).workerRevision},
        ethereum: {address: "", chainId: "0x1"}, solana: {publicKey}};
    harness.applyDecodedEnvelope(harness.provider, {id, name: "connect", kind: "result", result: {publicKey}, state});
}

function publicKey(value = firstSolanaKey) {
    return {toString() { return value; }};
}

function overrideProviderPublicKey(key, behavior) {
    let reads = 0;
    key.stringValue = secondSolanaKey;
    for (const method of ["toString", "toBase58", "toJSON", "toBytes", "toBuffer"]) {
        Object.defineProperty(key, method, {
            configurable: true,
            get() {
                reads += 1;
                if (behavior === "throw") { throw new Error("Public key accessed"); }
                return () => method === "toBytes" || method === "toBuffer"
                    ? new Uint8Array(32).fill(9)
                    : secondSolanaKey;
            },
        });
    }
    return () => reads;
}

function connectedSolanaHarness(publicKey = firstSolanaKey, extraGlobals = {}) {
    const configuration = {isConnected: true, publicKey};
    const harness = solanaHarness(configuration, extraGlobals);
    applySolanaConfiguration(harness, {
        publicKey: configuration.publicKey,
        isConnected: configuration.isConnected,
        workerRevision: 1,
    });
    return harness;
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

function sdkTransactionFixture(kind, wallet, cosigner) {
    const instruction = new solanaSDK.TransactionInstruction({
        keys: [
            {pubkey: wallet.publicKey, isSigner: true, isWritable: false},
            {pubkey: cosigner.publicKey, isSigner: true, isWritable: true},
        ],
        programId: new solanaSDK.PublicKey(firstSolanaKey),
        data: Buffer.from([1]),
    });
    const recentBlockhash = new solanaSDK.PublicKey(
        new Uint8Array(32).fill(3)
    ).toBase58();
    const legacy = kind === "legacy";
    let transaction;
    if (legacy) {
        transaction = new solanaSDK.Transaction({
            feePayer: cosigner.publicKey,
            recentBlockhash,
        }).add(instruction);
        transaction.partialSign(cosigner);
    } else {
        const message = new solanaSDK.TransactionMessage({
            payerKey: cosigner.publicKey,
            recentBlockhash,
            instructions: [instruction],
        });
        transaction = new solanaSDK.VersionedTransaction(
            kind === "v0"
                ? message.compileToV0Message()
                : message.compileToLegacyMessage()
        );
        transaction.sign([cosigner]);
    }
    const deserialize = bytes => legacy
        ? solanaSDK.Transaction.from(bytes)
        : solanaSDK.VersionedTransaction.deserialize(bytes);
    const expected = deserialize(transaction.serialize({
        requireAllSignatures: false,
        verifySignatures: false,
    }));
    if (legacy) {
        expected.partialSign(wallet);
    } else {
        expected.sign([wallet]);
    }
    const signerIndex = legacy
        ? transaction.signatures.findIndex(entry => entry.publicKey.equals(wallet.publicKey))
        : transaction.message.staticAccountKeys.findIndex(key => key.equals(wallet.publicKey));
    assert.equal(signerIndex, 1);
    const cosignature = legacy
        ? transaction.signatures[0].signature
        : transaction.signatures[0];
    const base58 = moduleHarness(base58Source).exports;
    return {
        transaction,
        signatures: transaction.signatures,
        signerEntry: legacy ? transaction.signatures[signerIndex] : null,
        cosignature,
        cosignatureBytes: Buffer.from(cosignature),
        expectedBytes: Buffer.from(expected.serialize()),
        response: base58.encode(legacy
            ? expected.signatures[signerIndex].signature
            : expected.signatures[signerIndex]),
        deserialize,
        legacy,
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
    assert.equal(runtime.resolve(first, thenable), true);
    assert.equal((await first.promise), thenable);
    assert.equal(replacement.wireId, 3);
    assert.equal(runtime.owns(replacement), true);
    runtime.resolve(second, "second");
    runtime.resolve(replacement, "replacement");
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
    runtime.resolve(first, true);
    runtime.resolve(second, true);
    await Promise.all([first.promise, second.promise]);
});

test("OperationRuntime rejects copied and foreign operations with matching IDs", async () => {
    const {exports} = moduleHarness(operationRuntimeSource);
    const Runtime = exports.default;
    const runtime = new Runtime("local");
    const otherRuntime = new Runtime("other");
    const local = runtime.register({payload: {}});
    const foreign = otherRuntime.register({payload: {}});
    assert.equal(local.wireId, foreign.wireId);
    const copied = {...local};

    for (const handle of [copied, foreign]) {
        assert.equal(runtime.owns(handle), false);
        assert.equal(runtime.enqueue(handle), false);
        assert.equal(runtime.resolve(handle, "forged"), false);
        assert.equal(runtime.reject(handle, new Error("forged")), false);
        assert.equal(runtime.operation(local.wireId), local);
    }
    assert.equal(runtime.resolve(local, "local"), true);
    assert.equal(otherRuntime.resolve(foreign, "foreign"), true);
    assert.equal(await local.promise, "local");
    assert.equal(await foreign.promise, "foreign");
});

test("OperationRuntime dispatches and settles each queued operation once", async () => {
    const {exports} = moduleHarness(operationRuntimeSource);
    const runtime = new exports.default("runtime-generation");
    const record = runtime.register({payload: {}});
    assert.equal(runtime.enqueue(record), true);
    assert.equal(runtime.enqueue(record), false);
    assert.equal(runtime.drain(current => {
        assert.equal(current, record);
        assert.equal(runtime.enqueue(current), false);
        assert.equal(runtime.resolve(current, "done"), true);
        assert.equal(runtime.owns(current), false);
        assert.equal(runtime.operation(current.wireId), undefined);
        assert.equal(runtime.resolve(current, "duplicate"), false);
        assert.equal(runtime.reject(current, new Error("duplicate")), false);
    }), 1);
    assert.equal(await record.promise, "done");
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
    runtime.reject(overflow, new Error("loading limit"));

    const order = [];
    runtime.drain(record => {
        order.push(record.payload.name);
        runtime.resolve(record, true);
    });
    assert.deepEqual(order, ["first", "second"]);
    assert.equal(await overflowFailure, "loading limit");
    assert.deepEqual(await Promise.all([first.promise, second.promise]), [true, true]);
    assert.equal(runtime.phase, "ready");

    const ready = runtime.register({payload: {name: "ready"}});
    assert.equal(runtime.enqueue(ready), false);
    runtime.resolve(ready, true);
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
            runtime.reject(overflow, new Error("loading limit"));
        }
        runtime.resolve(record, true);
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
            runtime.resolve(record, true);
        }
    });

    assert.deepEqual(order, ["first", "reentrant"]);
    assert.equal(await firstFailure, "reset");
    assert.equal(await queuedFailure, "reset");
    assert.equal(await reentrant.promise, true);
    assert.equal(runtime.phase, "ready");
});

test("OperationRuntime drains a reentrant FIFO and rejects dispatch failures", async () => {
    const {exports} = moduleHarness(operationRuntimeSource);
    const Runtime = exports.default;
    const runtime = new Runtime("runtime-generation");
    const nested = runtime.register({originalId: 1, payload: {name: "nested"}});
    const outer = runtime.register({
        originalId: 1,
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
            runtime.resolve(record, true);
        } else if (record === outer) {
            throw new Error("dispatch failed");
        } else {
            runtime.resolve(record, true);
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
    assert.equal(runtime.owns(first), false);
    assert.equal(runtime.resolve(first, "late"), false);
    assert.equal(runtime.reject(first, new Error("late")), false);
    assert.equal(await firstRejected, "reset");
    const second = runtime.register({payload: {}});
    assert.equal(second.wireId, 2);
    const secondRejected = second.promise.catch(error => error.message);
    assert.equal(runtime.retire(new Error("retired")), 1);
    assert.equal(runtime.owns(second), false);
    assert.equal(runtime.resolve(second, "late"), false);
    assert.equal(runtime.reject(second, new Error("late")), false);
    assert.equal(await secondRejected, "retired");
    assert.equal(runtime.phase, "retired");
    assert.throws(() => runtime.register({payload: {}}), /retired/);
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

    assert.equal(harness.isReady(), false);
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
    harness.applyDecodedEnvelope({
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
    assert.equal(harness.applyDecodedEnvelope({
        id: 1,
        kind: "result",
        name: "signTransaction",
        result: "forged",
    }), false);
    assert.equal(harness.requests.length, 0);
    applyEthereumConfiguration(harness);
    assert.equal(harness.requests.length, 1);
    harness.applyDecodedEnvelope({
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
    harness.applyDecodedEnvelope({
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
    grantEthereum(harness, harness.requests.at(-1).id, "0x0000000000000000000000000000000000000001");
    assert.deepEqual(normalized(await enabled), [
        "0x0000000000000000000000000000000000000001",
    ]);
});

test("Ethereum string send ignores inherited parameters", async () => {
    const harness = ethereumHarness();
    applyEthereumConfiguration(harness);
    const prototype = vm.runInContext("Object.prototype", harness.context);
    try {
        prototype.params = 1n;
        assert.equal(await harness.provider.send("eth_chainId"), "0x1");

        prototype.params = ["unexpected"];
        const pending = new Promise((resolve, reject) => {
            harness.provider.send("eth_blockNumber", (error, result) => {
                error ? reject(error) : resolve(result);
            });
        });
        const message = harness.rpc[0].message;
        assert.equal(Object.hasOwn(JSON.parse(message.body), "params"), false);
        harness.applyDecodedEnvelope({
            id: message.id,
            kind: "result",
            result: "0x10",
        });
        assert.deepEqual(normalized(await pending), {
            id: message.id,
            jsonrpc: "2.0",
            result: "0x10",
        });
    } finally {
        delete prototype.params;
    }
});

test("Ethereum reads inherited signing parameters once", async () => {
    const harness = ethereumHarness();
    applyEthereumConfiguration(harness);
    let reads = 0;
    class SigningRequest {
        method = "personal_sign";
        get params() {
            reads += 1;
            return ["0x6869"];
        }
    }
    const pending = harness.provider.request(new SigningRequest());
    assert.equal(reads, 1);
    assert.equal(harness.requests[0].name, "signPersonalMessage");
    assert.deepEqual(normalized(harness.requests[0].data), {data: "0x6869"});
    harness.applyDecodedEnvelope({
        id: harness.requests[0].id,
        kind: "result",
        name: "signPersonalMessage",
        result: "0xsignature",
    });
    assert.equal(await pending, "0xsignature");
});

test("Ethereum send preserves inherited RPC parameters", async () => {
    const harness = ethereumHarness();
    applyEthereumConfiguration(harness);
    const params = ["0x0000000000000000000000000000000000000001", "latest"];
    class BalanceRequest {
        method = "eth_getBalance";
        get params() { return params; }
    }
    const pending = harness.provider.send(new BalanceRequest());
    assert.deepEqual(JSON.parse(harness.rpc[0].message.body).params, params);
    harness.applyDecodedEnvelope({
        id: harness.rpc[0].message.id,
        kind: "result",
        result: "0x10",
    });
    assert.equal(await pending, "0x10");
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
    harness.applyDecodedEnvelope({
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
        harness.applyDecodedEnvelope({
            id: harness.rpc[0].message.id,
            kind: "result",
            result: true,
        });
        harness.applyDecodedEnvelope({
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
    harness.applyDecodedEnvelope({
        id: harness.rpc[0].message.id,
        kind: "result",
        result: {number: "0x1"},
    });
    const result = await request;
    assert.deepEqual(Object.getOwnPropertyNames(result), ["number"]);
    assert.equal(Object.hasOwn(result, "toJSON"), false);
});

test("queued Ethereum wallet payloads retain caller JSON semantics and owned data", async () => {
    const harness = ethereumHarness();
    let serializationCalls = 0;
    const boxed = new Number(3);
    boxed.valueOf = () => 4;
    const transaction = {
        value: "0x1",
        boxed,
        custom: {toJSON() { serializationCalls += 1; return {value: 5}; }},
        date: new Date("2026-08-23T00:00:00.000Z"),
        omitted: undefined,
        sparse: [, undefined, 3],
        toJSON: "literal",
        ["__proto__"]: {value: 6},
    };
    const request = harness.provider.request({
        method: "eth_sendTransaction",
        params: [transaction],
    });
    transaction.value = "0xff";
    transaction.custom.toJSON = () => { throw new Error("Caller reread"); };
    transaction.sparse[2] = 9;
    const objectPrototype = vm.runInContext("Object.prototype", harness.context);
    const arrayPrototype = vm.runInContext("Array.prototype", harness.context);
    objectPrototype.toJSON = () => { throw new Error("Object prototype called"); };
    arrayPrototype.toJSON = () => { throw new Error("Array prototype called"); };
    try {
        applyEthereumConfiguration(harness);
        assert.equal(serializationCalls, 1);
        assert.deepEqual(normalized(harness.requests[0].data), {
            value: "0x1",
            boxed: 4,
            custom: {value: 5},
            date: "2026-08-23T00:00:00.000Z",
            sparse: [null, null, 3],
            toJSON: "literal",
            ["__proto__"]: {value: 6},
        });
    } finally {
        delete objectPrototype.toJSON;
        delete arrayPrototype.toJSON;
    }
    harness.applyDecodedEnvelope({
        id: harness.requests[0].id,
        kind: "result",
        name: "signTransaction",
        result: "0xhash",
    });
    assert.equal(await request, "0xhash");

    const cycle = {};
    cycle.self = cycle;
    for (const invalid of [cycle, {value: 1n}]) {
        await assert.rejects(harness.provider.request({
            method: "eth_sendTransaction",
            params: [invalid],
        }), error => error.code === -32602);
    }
    assert.equal(harness.requests.length, 1);
});

test("Ethereum wallet dispatch tolerates synchronous settlement and retirement", async () => {
    const harness = ethereumHarness();
    applyEthereumConfiguration(harness);
    let settlements = 0;
    harness.setRequestObserver(message => {
        harness.applyDecodedEnvelope({
            id: message.id,
            kind: "result",
            name: message.name,
            result: "0xhash",
        });
        harness.retire(new Error("Replaced"));
    });
    const request = harness.provider.request({
        method: "eth_sendTransaction",
        params: [{value: "0x1"}],
    }).then(value => { settlements += 1; return value; });
    assert.equal(await request, "0xhash");
    assert.equal(settlements, 1);
    assert.equal(harness.requests.length, 1);
    assert.equal(harness.provider.selectedAddress, null);
});

test("Ethereum transaction values cannot be rewritten by inherited descriptor getters", async () => {
    const harness = ethereumHarness();
    applyEthereumConfiguration(harness);
    const prototype = vm.runInContext("Object.prototype", harness.context);
    let calls = 0;
    Object.defineProperty(prototype, "configurable", {
        configurable: true,
        get() {
            calls += 1;
            if (this.value === "0x1") { this.value = "0x2"; }
            return false;
        },
    });
    let pending;
    try {
        pending = harness.provider.request({
            method: "eth_sendTransaction",
            params: [{value: "0x1"}],
        });
        assert.equal(structuredClone(harness.requests[0].data).value, "0x1");
        assert.equal(calls, 0);
    } finally {
        delete prototype.configurable;
    }
    harness.applyDecodedEnvelope({
        id: harness.requests[0].id,
        kind: "result",
        name: "signTransaction",
        result: "0xhash",
    });
    assert.equal(await pending, "0xhash");
});

test("Ethereum chain request arrays retain their original wire shape", async () => {
    for (const method of ["wallet_addEthereumChain", "wallet_switchEthereumChain"]) {
        const harness = ethereumHarness();
        const pending = harness.provider.request({method, params: [[]]});
        const rejected = assert.rejects(pending, error => error.code === -32603);
        const prototype = vm.runInContext("Array.prototype", harness.context);
        prototype.chainId = "0x2";
        try {
            applyEthereumConfiguration(harness);
            assert.deepEqual(structuredClone(harness.requests[0].data), []);
        } finally {
            delete prototype.chainId;
        }
        harness.applyDecodedEnvelope({
            id: harness.requests[0].id,
            kind: "error",
            name: harness.requests[0].name,
            error: {code: -32603, message: "Invalid chain request"},
        });
        await rejected;
    }
});

test("queued Ethereum string signing dispatch does not invoke inherited serializers", async () => {
    for (const method of ["personal_sign", "eth_sign"]) {
        const harness = ethereumHarness();
        const pending = harness.provider.request({
            method,
            params: method === "personal_sign" ? ["0x41"] : ["0xaccount", "0x41"],
        });
        const prototype = vm.runInContext("Object.prototype", harness.context);
        let calls = 0;
        prototype.toJSON = () => {
            calls += 1;
            throw new Error("Object prototype serializer called");
        };
        try {
            applyEthereumConfiguration(harness);
            assert.equal(harness.requests.length, 1);
            assert.equal(harness.requests[0].name, "signPersonalMessage");
            assert.deepEqual(structuredClone(harness.requests[0].data), {data: "0x41"});
            assert.equal(calls, 0);
        } finally {
            delete prototype.toJSON;
        }
        harness.applyDecodedEnvelope({
            id: harness.requests[0].id,
            kind: "result",
            name: "signPersonalMessage",
            result: "0xsignature",
        });
        assert.equal(await pending, "0xsignature");
    }
});

test("Ethereum personal signing snapshots data after buffer conversion hooks", async () => {
    const harness = ethereumHarness();
    const pending = harness.provider.request({
        method: "personal_sign",
        params: [{type: "Buffer", data: [65]}],
    });
    const prototype = vm.runInContext("Object.prototype", harness.context);
    const original = prototype.valueOf;
    prototype.valueOf = function () {
        if (this.type === "Buffer") { this.extra = () => {}; }
        return original.call(this);
    };
    try {
        applyEthereumConfiguration(harness);
        assert.deepEqual(structuredClone(harness.requests[0].data), {
            data: {type: "Buffer", data: [65]},
        });
    } finally {
        prototype.valueOf = original;
    }
    harness.applyDecodedEnvelope({
        id: harness.requests[0].id,
        kind: "result",
        name: "signPersonalMessage",
        result: "0xsignature",
    });
    assert.equal(await pending, "0xsignature");
});

test("Ethereum emits authoritative deltas from copied state", () => {
    const firstAddress = "0x0000000000000000000000000000000000000001";
    const secondAddress = "0x0000000000000000000000000000000000000002";
    const harness = ethereumHarness({
        address: firstAddress,
        chainId: "0x1",
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

test("Ethereum configuration events precede bootstrap FIFO dispatch", async () => {
    const first = "0x0000000000000000000000000000000000000001";
    const second = "0x0000000000000000000000000000000000000002";
    const h = ethereumHarness({address: first, chainId: "0x1"});
    const order = [];
    h.provider.on("accountsChanged", () => { order.push("accounts"); });
    h.provider.on("chainChanged", () => { order.push("chain"); });
    h.setRPCObserver(() => order.push("request"));
    const pending = h.provider.request({method: "eth_blockNumber"});
    applyEthereumConfiguration(h, second, "0x2");
    assert.deepEqual(order, ["accounts", "chain", "request"]);
    h.applyDecodedEnvelope({kind: "result", id: h.rpc[0].message.id, result: "0x1"});
    assert.equal(await pending, "0x1");
});

test("malformed raw configuration cannot interrupt a copied Ethereum first drain", async () => {
    let harness;
    let interruptDrain = false;
    harness = inpageHarness({beforeEvaluate(window) {
        const postMessage = window.postMessage;
        window.postMessage = message => {
            postMessage(message);
            if (interruptDrain && message.kind === "rpc") {
                interruptDrain = false;
                harness.dispatch({
                    kind: "response",
                    response: {kind: "configuration", state: null},
                });
            }
        };
    }});
    const firstAddress = "0x0000000000000000000000000000000000000001";
    const secondAddress = "0x0000000000000000000000000000000000000002";
    dispatchConfigurations(harness, {address: firstAddress});
    harness.evaluate();
    const events = [];
    harness.window.ethereum.on("accountsChanged", accounts => {
        events.push(["accountsChanged", normalized(accounts)]);
    });
    harness.window.ethereum.on("chainChanged", chainId => {
        events.push(["chainChanged", chainId]);
    });
    const pending = harness.window.ethereum.request({method: "eth_blockNumber"});
    interruptDrain = true;
    dispatchConfigurations(harness, {address: secondAddress, chainId: "0x2"});
    const request = pageMessages(harness, "rpc").at(-1);
    harness.dispatch({
        id: request.message.id,
        kind: "rpc",
        response: terminalResponse({
            id: request.message.id, provider: "ethereum", name: null, result: "0x1",
        }),
    });
    assert.equal(await pending, "0x1");
    assert.deepEqual(events, [
        ["accountsChanged", [secondAddress]],
        ["chainChanged", "0x2"],
    ]);
});

test("Ethereum contains listener failures while emitting state changes", () => {
    const harness = ethereumHarness();
    const firstAddress = "0x0000000000000000000000000000000000000001";
    const secondAddress = "0x0000000000000000000000000000000000000002";
    applyEthereumConfiguration(harness, firstAddress, "0x1");
    let laterListener = 0;
    const chains = [];
    harness.provider.on("chainChanged", chainId => chains.push(chainId));
    harness.provider.on("accountsChanged", () => {
        throw new Error("listener failed");
    });
    harness.provider.on("accountsChanged", () => {
        laterListener += 1;
    });
    harness.applyDecodedEnvelope({
        kind: "configuration",
        configuration: {address: secondAddress, chainId: "0x2"},
    });
    assert.equal(laterListener, 0);
    assert.equal(harness.provider.selectedAddress, secondAddress);
    assert.deepEqual(chains, ["0x2"]);
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
    harness.applyDecodedEnvelope({
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
    assert.equal(harness.retire(), true);
    await assert.rejects(pending, error => error.code === 4900);
    assert.equal(harness.provider.isConnected(), false);
    assert.equal(harness.snapshot().phase, "retired");
    assert.equal(harness.applyDecodedEnvelope({
        id: harness.requests.at(-1).id,
        kind: "result",
        name: harness.requests.at(-1).name,
        result: "late",
    }), false);
});

test("Ethereum error terminals cannot change authorization", async () => {
    const h = ethereumHarness();
    const address = "0x0000000000000000000000000000000000000001";
    applyEthereumConfiguration(h, address);
    const pending = h.provider.request({method: "personal_sign", params: ["0x01"]});
    h.applyDecodedEnvelope({id: h.requests[0].id, name: "signPersonalMessage", kind: "error", error: {code: 4100, message: "Unauthorized"}});
    await assert.rejects(pending, error => error.code === 4100);
    assert.equal(h.provider.selectedAddress, address);
    applyEthereumConfiguration(h);
    assert.equal(h.provider.selectedAddress, null);
});

test("Ethereum chain results settle without modifying account or network state", async () => {
    const address = "0x0000000000000000000000000000000000000001";
    for (const method of ["wallet_switchEthereumChain", "wallet_addEthereumChain"]) {
        const h = ethereumHarness();
        applyEthereumConfiguration(h, address);
        const pending = h.provider.request({method, params: [{chainId: "0x2"}]});
        h.applyDecodedEnvelope({id: h.requests[0].id, name: h.requests[0].name, kind: "result", result: null});
        assert.equal(await pending, null);
        assert.equal(h.provider.chainId, "0x1");
        assert.equal(h.provider.selectedAddress, address);
        applyEthereumConfiguration(h, address, "0x2");
        assert.equal(h.provider.chainId, "0x2");
    }
});

test("Ethereum same-chain switches preserve pending signing without wallet transport", async () => {
    const harness = ethereumHarness();
    const address = "0x0000000000000000000000000000000000000001";
    applyEthereumConfiguration(harness, address, "0x1");
    const signing = harness.provider.request({
        method: "personal_sign",
        params: ["0x01"],
    });
    const signingRequest = harness.requests[0];
    const before = normalized(harness.snapshot());
    const events = [];
    harness.provider.on("accountsChanged", accounts => events.push(accounts));
    harness.provider.on("chainChanged", chainId => events.push(chainId));

    const result = await harness.provider.request({
        method: "wallet_switchEthereumChain",
        params: [{chainId: "0x1"}],
    });

    assert.equal(result, null);
    assert.equal(harness.requests.length, 1);
    assert.deepEqual(normalized(harness.snapshot()), before);
    assert.deepEqual(events, []);
    harness.applyDecodedEnvelope({
        id: signingRequest.id,
        kind: "result",
        name: signingRequest.name,
        result: "0xsignature",
    });
    assert.equal(await signing, "0xsignature");
});

test("Ethereum queued switches compare the loaded chain without granting accounts", async () => {
    const harness = ethereumHarness();
    const sameChain = harness.provider.request({
        method: "wallet_switchEthereumChain",
        params: [{chainId: "0x2"}],
    });
    const differentChain = harness.provider.request({
        method: "wallet_switchEthereumChain",
        params: [{chainId: "0x1"}],
    });
    assert.equal(harness.requests.length, 0);

    applyEthereumConfiguration(harness, "", "0x2");

    assert.equal(await sameChain, null);
    assert.equal(harness.requests.length, 1);
    const request = harness.requests[0];
    assert.equal(request.data.chainId, "0x1");
    applyEthereumConfiguration(harness, "", "0x1");
    harness.applyDecodedEnvelope({
        id: request.id,
        kind: "result",
        name: request.name,
        result: null,
    });
    assert.equal(await differentChain, null);
    assert.equal(harness.provider.chainId, "0x1");
    assert.equal(harness.provider.selectedAddress, null);
});

test("Ethereum normalizes external chain IDs without mutating caller data", async () => {
    for (const method of ["wallet_addEthereumChain", "wallet_switchEthereumChain"]) {
        for (const chainId of ["0xA", "0xaB"]) {
            const harness = ethereumHarness();
            applyEthereumConfiguration(harness);
            const input = Object.freeze({chainId, chainName: "Test chain"});
            const pending = harness.provider.request({method, params: [input]});
            const request = harness.requests[0];
            assert.deepEqual(normalized(request.data), {
                chainId: chainId.toLowerCase(),
                chainName: input.chainName,
            });
            assert.equal(input.chainId, chainId);
            applyEthereumConfiguration(harness, "", chainId.toLowerCase());
            harness.applyDecodedEnvelope({
                id: request.id,
                kind: "result",
                name: request.name,
                result: null,
            });
            assert.equal(await pending, null);
            assert.equal(harness.provider.chainId, chainId.toLowerCase());
        }
    }
});

test("Ethereum normalizes uppercase IDs before comparing the current chain", async () => {
    const harness = ethereumHarness();
    applyEthereumConfiguration(harness, "", "0xa");
    const result = await harness.provider.request({
        method: "wallet_switchEthereumChain",
        params: [{chainId: "0xA"}],
    });
    assert.equal(result, null);
    assert.equal(harness.requests.length, 0);
    assert.equal(harness.provider.chainId, "0xa");
});

test("Ethereum chain requests ignore later String prototype changes", async () => {
    for (const method of ["wallet_addEthereumChain", "wallet_switchEthereumChain"]) {
        for (const name of ["startsWith", "toLowerCase"]) {
            const harness = ethereumHarness();
            applyEthereumConfiguration(harness);
            const prototype = vm.runInContext("String.prototype", harness.context);
            const original = prototype[name];
            prototype[name] = name === "startsWith" ? () => false : () => "0x1";
            let pending;
            try {
                pending = harness.provider.request({
                    method,
                    params: [{chainId: "0xA"}],
                });
                pending.catch(() => {});
                assert.equal(harness.requests.length, 1);
                assert.equal(harness.requests[0].data.chainId, "0xa");
            } finally {
                prototype[name] = original;
            }
            const request = harness.requests[0];
            applyEthereumConfiguration(harness, "", "0xa");
            harness.applyDecodedEnvelope({
                id: request.id,
                kind: "result",
                name: request.name,
                result: null,
            });
            assert.equal(await pending, null);
            assert.equal(harness.provider.chainId, "0xa");
        }
    }
});

test("Ethereum rejects invalid chain IDs before wallet transport", async () => {
    const invalidChainIds = [
        "0XA",
        "0x01",
        "0x0A",
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
    accountsHarness.applyDecodedEnvelope({
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
    chainHarness.applyDecodedEnvelope({
        id: chainHarness.requests[0].id,
        kind: "result",
        name: "switchEthereumChain",
        result: "invalid",
    });
    await assert.rejects(chain, error => error.code === -32603);
    assert.equal(chainHarness.provider.chainId, "0x1");
    assert.equal(chainHarness.provider.selectedAddress, address);
});

test("malformed raw configuration during request normalization leaves Ethereum usable", async () => {
    const harness = inpageHarness();
    dispatchConfigurations(harness);
    const trigger = {
        toJSON() {
            harness.dispatch({
                kind: "response",
                response: {kind: "configuration", state: null},
            });
            return {};
        },
    };
    const pending = harness.window.ethereum.request({method: "eth_custom", params: [trigger]});
    const request = pageMessages(harness, "rpc").at(-1);
    assert.ok(request);
    harness.dispatch({
        id: request.message.id,
        kind: "rpc",
        response: terminalResponse({
            id: request.message.id, provider: "ethereum", name: null, result: true,
        }),
    });
    assert.equal(await pending, true);
    assert.equal(await harness.window.ethereum.request({method: "eth_chainId"}), "0x1");
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
    assert.equal(harness.snapshot().phase, "retired");
});

test("late Ethereum revocation preserves newer account authorization", async () => {
    const firstAddress = "0x0000000000000000000000000000000000000001";
    const secondAddress = "0x0000000000000000000000000000000000000002";
    for (const address of [firstAddress, secondAddress]) {
        for (const kind of ["result", "error"]) {
            const harness = ethereumHarness();
            applyEthereumConfiguration(harness, firstAddress);
            const revocation = harness.provider.request({
                method: "wallet_revokePermissions",
                params: [{eth_accounts: {}}],
            });
            applyEthereumConfiguration(harness);
            harness.applyDecodedEnvelope({
                kind: "configuration",
                configuration: {address, chainId: "0x1"},
            });
            const accountChanges = [];
            harness.provider.on("accountsChanged", accounts => {
                accountChanges.push(accounts);
            });
            const settled = kind === "result"
                ? assert.doesNotReject(revocation)
                : assert.rejects(revocation, error => error.code === -32603);
            harness.applyDecodedEnvelope({
                id: harness.disconnects[0].id,
                kind,
                name: "revokePermissions",
                ...(kind === "result" ? {result: null} : {
                    error: {code: -32603, message: "Failed to revoke permissions"},
                }),
            });
            await settled;
            applyEthereumConfiguration(harness, address);
            assert.equal(harness.provider.selectedAddress, address);
            assert.equal(harness.provider.selectedAddress, address);
            assert.deepEqual(accountChanges, []);
        }
    }
});

test("Ethereum revoke acknowledgement preserves a pending reconnect", async () => {
    const harness = ethereumHarness();
    const address = "0x0000000000000000000000000000000000000001";
    applyEthereumConfiguration(harness, address);
    const revocation = harness.provider.request({
        method: "wallet_revokePermissions",
        params: [{eth_accounts: {}}],
    });
    applyEthereumConfiguration(harness);
    const reconnect = harness.provider.request({method: "eth_requestAccounts"});
    harness.applyDecodedEnvelope({
        id: harness.disconnects[0].id,
        kind: "result",
        name: "revokePermissions",
        result: null,
    });
    await revocation;
    grantEthereum(harness, harness.requests.at(-1).id, address);
    assert.deepEqual(normalized(await reconnect), [address]);
    assert.equal(harness.provider.selectedAddress, address);
});

test("empty requestAccounts success cannot restore revoked authorization", async () => {
    const h = ethereumHarness();
    applyEthereumConfiguration(h);
    const pending = h.provider.request({method: "eth_requestAccounts"});
    h.applyDecodedEnvelope({id: h.requests[0].id, name: "requestAccounts", kind: "result", result: []});
    assert.deepEqual(normalized(await pending), []);
    assert.equal(h.provider.selectedAddress, null);
});

test("Ethereum snapshots grant and revoke the same account with increasing revisions", async () => {
    const h = ethereumHarness();
    const address = "0x0000000000000000000000000000000000000001";
    applyEthereumConfiguration(h, address);
    const revision = h.snapshot().workerRevision;
    applyEthereumConfiguration(h);
    assert.equal(h.provider.selectedAddress, null);
    const pending = h.provider.request({method: "eth_requestAccounts"});
    grantEthereum(h, h.requests.at(-1).id, address);
    assert.deepEqual(normalized(await pending), [address]);
    assert.equal(h.provider.selectedAddress, address);
    assert.equal(h.snapshot().workerRevision, revision + 2);
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
    harness.applyDecodedEnvelope({
        configuration: {address: secondAddress, chainId: "0x1"},
        kind: "configuration",
    });
    harness.applyDecodedEnvelope({
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
    harness.applyDecodedEnvelope({
        id: currentRequest.id,
        kind: "result",
        name: currentRequest.name,
        result: "0xcurrent",
    });
    await assert.rejects(current, error => error.code === 4100);
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
    harness.applyDecodedEnvelope({
        configuration: {address: secondAddress, chainId: "0x1"},
        kind: "configuration",
    });
    harness.applyDecodedEnvelope({
        approvalCommitted: true,
        id: request.id,
        kind: "result",
        name: request.name,
        result: "0xsignature",
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
    harness.applyDecodedEnvelope({
        configuration: {address: newerAddress, chainId: "0x1"},
        kind: "configuration",
    });
    harness.applyDecodedEnvelope({
        approvalCommitted: true,
        id: request.id,
        kind: "result",
        name: "requestAccounts",
        result: [approvedAddress],
    });

    assert.deepEqual(normalized(await accounts), [approvedAddress]);
    assert.equal(harness.provider.selectedAddress, newerAddress);
});

test("invalid initial Ethereum revision neither drains nor emits connect", async () => {
    const h = ethereumHarness();
    let connects = 0;
    h.provider.on("connect", () => connects++);
    const pending = h.provider.request({method: "eth_chainId"});
    assert.equal(h.applyDecodedEnvelope({kind: "configuration", workerRevision: -1, configuration: {address: "", chainId: "0x2"}}), false);
    assert.equal(h.isReady(), false);
    assert.equal(connects, 0);
    applyEthereumConfiguration(h, "", "0x3");
    assert.equal(await pending, "0x3");
    assert.equal(connects, 1);
});

test("Ethereum first connect follows current configuration events synchronously", () => {
    for (const retireDuring of [null, "accountsChanged", "chainChanged", "networkChanged"]) {
        const harness = ethereumHarness({address: "", chainId: "0x1"});
        const events = [];
        for (const name of ["accountsChanged", "chainChanged", "networkChanged", "connect"]) {
            harness.provider.on(name, value => {
                events.push(name);
                if (name === "connect") {
                    assert.equal(Object.isFrozen(value), true);
                    assert.deepEqual(normalized(value), {chainId: "0x2"});
                }
                if (name === retireDuring) { harness.retire(); }
            });
        }
        harness.applyDecodedEnvelope({
            kind: "configuration",
            configuration: {
                address: "0x0000000000000000000000000000000000000001",
                chainId: "0x2",
            },
        });
        if (retireDuring === null) {
            assert.deepEqual(events, [
                "accountsChanged", "chainChanged", "networkChanged", "connect",
            ]);
        } else {
            assert.equal(events.includes("connect"), false);
        }
        harness.runTimers();
        assert.equal(events.filter(name => name === "connect").length,
            retireDuring === null ? 1 : 0);
    }
});

test("Ethereum replays one authoritative connect to late public listeners", () => {
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

test("Ethereum configuration reserves connect replay before later page timers", () => {
    for (const removeListener of [false, true]) {
        const harness = ethereumHarness();
        harness.runTimers();
        const events = [];
        const listener = value => {
            assert.deepEqual(normalized(value), {chainId: "0x2"});
            events.push("connect");
        };
        applyEthereumConfiguration(harness, "", "0x2");
        harness.context.setTimeout(() => {
            events.push("page timer");
            if (removeListener) {
                harness.provider.removeListener("connect", listener);
            }
        }, 1);
        harness.provider.on("connect", listener);
        assert.deepEqual(events, []);
        harness.runTimers();
        assert.deepEqual(events, ["connect", "page timer"]);
    }
});

test("public connect emits do not consume the authoritative replay", () => {
    const harness = ethereumHarness();
    applyEthereumConfiguration(harness, "", "0x3");
    const connects = [];
    harness.provider.on("connect", value => {
        connects.push(normalized(value));
    });

    assert.equal(harness.provider.emit("connect", {chainId: "0x999"}), false);
    harness.runTimers();

    assert.deepEqual(connects, [{chainId: "0x3"}]);
    harness.provider.on("connect", value => {
        connects.push(["later", normalized(value)]);
    });
    harness.runTimers();
    assert.deepEqual(connects, [{chainId: "0x3"}]);
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

test("Ethereum connect replay retains its scheduler and contains listener inspection failures", () => {
    const harness = ethereumHarness();
    applyEthereumConfiguration(harness, "", "0x6");
    const connects = [];
    vm.runInContext("setTimeout = () => { throw new Error('replaced timer'); }", harness.context);
    harness.provider.on("connect", value => connects.push(normalized(value)));
    const events = Object.getOwnPropertyDescriptor(harness.provider, "_events");
    Object.defineProperty(harness.provider, "_events", {
        configurable: true,
        get() { throw new Error("listener inspection failed"); },
    });
    assert.doesNotThrow(() => harness.runTimers());
    Object.defineProperty(harness.provider, "_events", events);
    assert.deepEqual(connects, []);
    harness.provider.once("connect", value => connects.push(normalized(value)));
    harness.runTimers();
    assert.deepEqual(connects, [{chainId: "0x6"}, {chainId: "0x6"}]);
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
    const copied = inpageHarness();
    dispatchConfigurations(copied);
    copied.evaluate();
    const connects = [];
    copied.window.ethereum.on("connect", value => connects.push(normalized(value)));
    copied.runTimers();
    assert.deepEqual(connects, []);
    dispatchConfigurations(copied, {chainId: "0x4"});
    assert.deepEqual(connects, []);
    copied.runTimers();
    assert.deepEqual(connects, [{chainId: "0x4"}]);

    const retired = ethereumHarness();
    applyEthereumConfiguration(retired, "", "0x5");
    let retiredConnects = 0;
    retired.provider.on("connect", () => { retiredConnects += 1; });
    retired.retire();
    retired.runTimers();
    assert.equal(retiredConnects, 0);
});

test("Ethereum retirement preserves connect replay history", async () => {
    for (const wasReady of [false, true]) {
        const harness = inpageHarness();
        const provider = harness.window.ethereum;
        const connects = [];
        provider.on("connect", value => connects.push(["first", value.chainId]));
        if (wasReady) {
            dispatchConfigurations(harness);
            harness.runTimers();
            connects.length = 0;
        }

        harness.window.bigWalletInpageProviderGenerationToken = "stale";
        await assert.rejects(provider.request({method: "eth_chainId"}), error => error.code === 4900);
        harness.evaluate();
        assert.equal(harness.window.ethereum, provider);
        dispatchConfigurations(harness, {chainId: "0x2"});
        assert.deepEqual(connects, wasReady ? [] : [["first", "0x2"]]);
        provider.on("connect", value => connects.push(["late", value.chainId]));
        dispatchConfigurations(harness, {chainId: "0x3"});
        harness.runTimers();
        assert.deepEqual(connects, wasReady
            ? [["first", "0x3"], ["late", "0x3"]]
            : [["first", "0x2"]]);
    }
});

test("Ethereum connect replay waits for raw bootstrap failure recovery", async () => {
    const harness = inpageHarness();
    const pending = harness.window.ethereum.request({method: "eth_chainId"});
    harness.dispatch({kind: "response", response: {
        kind: "configurationError",
        error: {code: 4900, message: "Failed to communicate with Big Wallet"},
    }});
    await assert.rejects(pending, error => error.code === 4900);
    const connects = [];
    harness.window.ethereum.on("connect", value => connects.push(normalized(value)));
    harness.runTimers();
    assert.deepEqual(connects, []);
    dispatchConfigurations(harness, {chainId: "0x7"});
    harness.runTimers();
    assert.deepEqual(connects, [{chainId: "0x7"}]);
});

test("invalid initial Solana revision preserves the loading queue", async () => {
    const h = solanaHarness();
    const pending = h.provider.connect();
    assert.equal(applySolanaConfiguration(h, {workerRevision: -1}), false);
    assert.equal(h.requests.length, 0);
    applySolanaConfiguration(h);
    grantSolana(h, h.requests[0].id, firstSolanaKey);
    assert.equal((await pending).publicKey.toString(), firstSolanaKey);
});

test("Solana bounds loading work without retiring the ready provider", async () => {
    const harness = solanaHarness();
    const connections = Array.from({length: 65}, () => harness.provider.connect());
    const overflow = assert.rejects(connections[64], error => error.code === 4900);

    applySolanaConfiguration(harness, {
        isConnected: true,
        publicKey: firstSolanaKey,
        workerRevision: 1,
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
    assert.equal(harness.applyDecodedEnvelope(harness.provider, {
        id: 2,
        kind: "result",
        name: "connect",
        result: {publicKey: firstSolanaKey},
    }), false);
    assert.equal(harness.requests.length, 0);
    applySolanaConfiguration(harness);
    assert.equal(harness.requests.length, 1);
    grantSolana(harness, harness.requests[0].id, firstSolanaKey);
    assert.equal((await connection).publicKey.toString(), firstSolanaKey);
});

test("Solana late connect cannot overwrite newer authorization", async () => {
    const harness = solanaHarness();
    applySolanaConfiguration(harness);
    const connection = harness.provider.connect();
    applySolanaConfiguration(harness, {
        isConnected: true,
        publicKey: secondSolanaKey,
        workerRevision: 1,
    });
    harness.applyDecodedEnvelope(harness.provider, {
        id: harness.requests[0].id,
        kind: "result",
        name: "connect",
        result: {publicKey: firstSolanaKey},
    });
    await assert.rejects(connection, error => error.code === 4100);
    assert.equal(harness.provider.publicKey.toString(), secondSolanaKey);
});

test("Solana connect without a snapshot cannot authorize an account", async () => {
    const h = solanaHarness();
    applySolanaConfiguration(h);
    const pending = h.provider.connect();
    h.applyDecodedEnvelope(h.provider, {kind: "result", id: h.requests[0].id, name: "connect", result: {publicKey: firstSolanaKey}});
    await assert.rejects(pending, error => error.code === 4100);
    assert.equal(h.provider.publicKey, null);
});

test("Solana silent connect never posts without a trusted account", async () => {
    const harness = solanaHarness();
    const connection = harness.standardProvider.standardConnect({silent: true});
    assert.equal(harness.requests.length, 0);
    applySolanaConfiguration(harness);
    assert.deepEqual(normalized(await connection), {accounts: []});
    assert.equal(harness.requests.length, 0);
});

test("Solana connect uses an existing authoritative account without another event", async () => {
    const h = connectedSolanaHarness();
    let events = 0;
    h.standardProvider.on("connect", () => events++);
    const result = await h.provider.connect();
    assert.equal(result.publicKey.toString(), firstSolanaKey);
    assert.equal(h.requests.length, 0);
    assert.equal(events, 0);
});

test("Solana drains loading connects FIFO and rejects a stale grant", async () => {
    const h = solanaHarness();
    const first = h.provider.connect();
    const second = h.provider.connect();
    applySolanaConfiguration(h);
    assert.deepEqual(h.requests.map(x => x.id), [2, 4]);
    grantSolana(h, 2, firstSolanaKey);
    assert.equal((await first).publicKey.toString(), firstSolanaKey);
    applySolanaConfiguration(h);
    h.applyDecodedEnvelope(h.provider, {id: 4, name: "connect", kind: "result", result: {publicKey: firstSolanaKey}});
    await assert.rejects(second, error => error.code === 4100);
    assert.equal(h.provider.publicKey, null);
});

test("Solana shares disconnect work and waits for authoritative revocation", async () => {
    const h = connectedSolanaHarness();
    const first = h.provider.disconnect();
    const second = h.provider.externalDisconnect();
    assert.equal(first, second);
    assert.equal(h.disconnects.length, 1);
    assert.equal(h.provider.publicKey.toString(), firstSolanaKey);
    applySolanaConfiguration(h);
    h.applyDecodedEnvelope(h.provider, {id: h.disconnects[0].id, name: "revokePermissions", kind: "result", result: null});
    assert.equal(await first, true);
    assert.equal(h.provider.publicKey, null);
    applySolanaConfiguration(h, {publicKey: firstSolanaKey});
    assert.equal(h.provider.publicKey.toString(), firstSolanaKey);
});

test("Solana starts a new disconnect after authorization changes", async () => {
    const harness = solanaHarness({
        isConnected: true,
        publicKey: firstSolanaKey,
        workerRevision: 0,
    });
    applySolanaConfiguration(harness, {
        isConnected: true,
        publicKey: firstSolanaKey,
    });
    const first = harness.provider.disconnect();

    applySolanaConfiguration(harness, {
        isConnected: true,
        publicKey: secondSolanaKey,
        workerRevision: 1,
    });
    const second = harness.provider.disconnect();

    assert.notEqual(first, second);
    assert.equal(harness.disconnects.length, 2);
    harness.applyDecodedEnvelope(harness.provider, {
        id: harness.disconnects[0].id,
        kind: "result",
        name: "revokePermissions",
        result: null,
    });
    assert.equal(await first, true);
    assert.equal(harness.provider.publicKey.toString(), secondSolanaKey);

    applySolanaConfiguration(harness);
    harness.applyDecodedEnvelope(harness.provider, {
        id: harness.disconnects[1].id,
        kind: "result",
        name: "revokePermissions",
        result: null,
    });
    assert.equal(await second, true);
    assert.equal(harness.provider.publicKey, null);
});

test("Solana failed disconnect preserves authorization and concurrent signing", async () => {
    const harness = solanaHarness({
        isConnected: true,
        publicKey: firstSolanaKey,
        workerRevision: 4,
    });
    applySolanaConfiguration(harness, {
        isConnected: true,
        publicKey: firstSolanaKey,
        workerRevision: 4,
    });
    const before = harness.Solana.snapshot(harness.provider);
    const disconnect = harness.provider.disconnect();
    const signing = harness.provider.signMessage(new Uint8Array([1]));
    const signingRequest = harness.requests.at(-1);

    assert.deepEqual(harness.Solana.snapshot(harness.provider), before);
    harness.applyDecodedEnvelope(harness.provider, {
        error: {code: -32603, message: "Failed to revoke permissions"},
        id: harness.disconnects[0].id,
        kind: "error",
        name: "revokePermissions",
    });
    await assert.rejects(disconnect, error => error.code === -32603);
    assert.deepEqual(harness.Solana.snapshot(harness.provider), before);

    harness.applyDecodedEnvelope(harness.provider, {
        id: signingRequest.id,
        kind: "result",
        name: "signMessage",
        result: validSignature,
    });
    assert.equal((await signing).signature.length, 64);
    assert.deepEqual(harness.Solana.snapshot(harness.provider), before);

    const transportFailure = solanaHarness(before);
    applySolanaConfiguration(transportFailure, {
        publicKey: before.publicKey,
        isConnected: before.isConnected,
        workerRevision: before.workerRevision,
    });
    transportFailure.setDisconnectPost(false);
    await assert.rejects(
        transportFailure.provider.disconnect(),
        error => error.code === 4900
    );
    assert.deepEqual(
        normalized(transportFailure.Solana.snapshot(transportFailure.provider)),
        normalized(before)
    );
    assert.equal(transportFailure.provider.retired, false);
});

test("successful Solana disconnect fences concurrent uncommitted signing", async () => {
    const harness = solanaHarness({
        isConnected: true,
        publicKey: firstSolanaKey,
        workerRevision: 2,
    });
    applySolanaConfiguration(harness, {
        isConnected: true,
        publicKey: firstSolanaKey,
        workerRevision: 2,
    });
    const disconnect = harness.provider.disconnect();
    const signing = harness.provider.signMessage(new Uint8Array([1]));
    const signingRejected = assert.rejects(
        signing,
        error => error.code === 4100
    );
    const signingRequest = harness.requests.at(-1);

    applySolanaConfiguration(harness);
    harness.applyDecodedEnvelope(harness.provider, {
        id: harness.disconnects[0].id,
        kind: "result",
        name: "revokePermissions",
        result: null,
    });
    assert.equal(await disconnect, true);
    assert.equal(harness.Solana.snapshot(harness.provider).workerRevision, 3);
    assert.equal(harness.provider.publicKey, null);

    harness.applyDecodedEnvelope(harness.provider, {
        id: signingRequest.id,
        kind: "result",
        name: "signMessage",
        result: validSignature,
    });
    await signingRejected;
});

test("a fresh generation accepts a lower authoritative revision than its copied baseline", () => {
    const h = solanaHarness({publicKey: firstSolanaKey, isConnected: true, workerRevision: 10});
    applySolanaConfiguration(h, {publicKey: secondSolanaKey, workerRevision: 0});
    assert.equal(h.provider.publicKey.toString(), secondSolanaKey);
    assert.equal(h.Solana.snapshot(h.provider).workerRevision, 0);
});

test("stale Solana snapshots cannot restore a revoked account", () => {
    const h = connectedSolanaHarness();
    applySolanaConfiguration(h, {workerRevision: 3});
    applySolanaConfiguration(h, {publicKey: firstSolanaKey, workerRevision: 2});
    assert.equal(h.provider.publicKey, null);
    assert.equal(h.Solana.snapshot(h.provider).workerRevision, 3);
    applySolanaConfiguration(h, {publicKey: firstSolanaKey, workerRevision: 4});
    assert.equal(h.provider.publicKey.toString(), firstSolanaKey);
});

test("same-account Solana revisions fence operations without duplicate account events", async () => {
    const h = connectedSolanaHarness();
    let events = 0;
    h.standardProvider.on("accountChanged", () => events++);
    const signing = h.provider.signMessage(new Uint8Array([1]));
    applySolanaConfiguration(h, {publicKey: firstSolanaKey, workerRevision: 4});
    applySolanaConfiguration(h, {publicKey: firstSolanaKey, workerRevision: 4});
    h.applyDecodedEnvelope(h.provider, {id: h.requests[0].id, name: "signMessage", kind: "result", result: validSignature});
    await assert.rejects(signing, error => error.code === 4100);
    assert.equal(events, 0);
    assert.equal(h.Solana.snapshot(h.provider).workerRevision, 4);
});

test("disconnected Solana snapshots advance authority without reconnecting from terminals", async () => {
    const h = solanaHarness();
    applySolanaConfiguration(h);
    const connecting = h.provider.connect();
    applySolanaConfiguration(h, {workerRevision: 7});
    h.applyDecodedEnvelope(h.provider, {id: h.requests[0].id, name: "connect", kind: "result", result: {publicKey: firstSolanaKey}, approvalCommitted: true});
    assert.equal((await connecting).publicKey.toString(), firstSolanaKey);
    assert.equal(h.provider.publicKey, null);
    assert.equal(h.Solana.snapshot(h.provider).workerRevision, 7);
});

test("Solana rejects invalid worker revisions without changing authorization", () => {
    const h = connectedSolanaHarness();
    const before = h.Solana.snapshot(h.provider);
    for (const revision of [-1, NaN, Infinity, Number.MAX_SAFE_INTEGER + 1]) {
        assert.equal(applySolanaConfiguration(h, {workerRevision: revision}), false);
        assert.deepEqual(h.Solana.snapshot(h.provider), before);
    }
});

test("Solana reconnect is authorized by its snapshot before settlement", async () => {
    const h = connectedSolanaHarness();
    applySolanaConfiguration(h);
    const pending = h.provider.connect();
    grantSolana(h, h.requests[0].id, firstSolanaKey);
    assert.equal((await pending).publicKey.toString(), firstSolanaKey);
    assert.equal(h.provider.publicKey.toString(), firstSolanaKey);
});

test("Solana accepts raw ArrayBuffer messages", async () => {
    const harness = solanaHarness({
        isConnected: true,
        publicKey: firstSolanaKey,
        workerRevision: 1,
    });
    applySolanaConfiguration(harness, {
        isConnected: true,
        publicKey: firstSolanaKey,
        workerRevision: 1,
    });
    const bytes = new Uint8Array([1, 2, 3]);
    const signing = harness.provider.signMessage(bytes.buffer);
    assert.equal(harness.requests.at(-1).body.object.params.message, "0x010203");
    harness.applyDecodedEnvelope(harness.provider, {
        id: harness.requests.at(-1).id,
        kind: "result",
        name: "signMessage",
        result: validSignature,
    });
    assert.equal((await signing).signature.length, 64);
});

test("queued Solana connect and message requests retain admission snapshots", async () => {
    const cases = [
        {method: "connect", params: undefined, expected: undefined},
        {
            method: "connect",
            params: {onlyIfTrusted: false, context: {values: [1]}},
            expected: {onlyIfTrusted: false, context: {values: [1]}},
        },
        {
            method: "signMessage",
            params: {message: new Uint8Array([1, 2]), display: "hex", context: {values: [1]}},
            expected: {message: "0x0102", display: "hex", messageEncoding: "hex", context: {values: [1]}},
        },
        {
            method: "signMessage",
            params: {message: "hello", display: "utf8", context: {values: [1]}},
            expected: {message: "hello", display: "utf8", messageEncoding: "utf8", context: {values: [1]}},
        },
    ];
    for (const {method, params, expected} of cases) {
        const harness = solanaHarness();
        const pending = harness.provider.request({method, params});
        const rejected = assert.rejects(pending, error => error.code === 4001);
        if (params) {
            params.context.values[0] = 9;
            if (method === "connect") {
                params.onlyIfTrusted = true;
            } else {
                if (params.message instanceof Uint8Array) { params.message.fill(9); }
                params.message = "changed";
                params.display = "changed";
            }
        }
        applySolanaConfiguration(harness, method === "connect" ? {} : {
            isConnected: true,
            publicKey: firstSolanaKey,
            workerRevision: 1,
        });
        assert.equal(harness.requests.length, 1, method);
        const request = harness.requests[0];
        assert.equal(Object.hasOwn(request.body.object, "params"), expected !== undefined);
        assert.deepEqual(structuredClone(request.body.object.params), expected);
        harness.applyDecodedEnvelope(harness.provider, {
            id: request.id,
            kind: "error",
            name: method,
            error: {code: 4001, message: "Canceled"},
        });
        await rejected;
    }
});

test("Solana message dispatch removes non-cloneable values added by normalization hooks", async () => {
    const harness = solanaHarness();
    let posted;
    harness.setRequestObserver(message => { posted = structuredClone(message); });
    const prototype = vm.runInContext("Object.prototype", harness.context);
    let calls = 0;
    Object.defineProperty(prototype, "messageEncoding", {
        configurable: true,
        set(value) {
            calls += 1;
            Object.defineProperty(this, "messageEncoding", {
                configurable: true,
                enumerable: true,
                value,
                writable: true,
            });
            this.extra = () => {};
        },
    });
    let pending;
    try {
        pending = harness.provider.signMessage(new Uint8Array([1]));
    } finally {
        delete prototype.messageEncoding;
    }
    const rejected = assert.rejects(pending, error => error.code === 4001);
    applySolanaConfiguration(harness, {
        isConnected: true,
        publicKey: firstSolanaKey,
        workerRevision: 1,
    });
    assert.equal(calls, 1);
    assert.equal(harness.requests.length, 1);
    assert.deepEqual(posted.body.object.params, {message: "0x01", messageEncoding: "hex"});
    harness.applyDecodedEnvelope(harness.provider, {
        id: posted.id,
        kind: "error",
        name: "signMessage",
        error: {code: 4001, message: "Canceled"},
    });
    await rejected;
});

test("queued Solana connect removes non-cloneable values added by dispatch hooks", async () => {
    const harness = solanaHarness();
    let posted;
    harness.setRequestObserver(message => { posted = structuredClone(message); });
    const pending = harness.provider.connect({});
    const rejected = assert.rejects(pending, error => error.code === 4001);
    const prototype = vm.runInContext("Object.prototype", harness.context);
    let calls = 0;
    Object.defineProperty(prototype, "onlyIfTrusted", {
        configurable: true,
        get() {
            calls += 1;
            this.extra = () => {};
            return false;
        },
    });
    try {
        applySolanaConfiguration(harness);
    } finally {
        delete prototype.onlyIfTrusted;
    }
    assert.equal(calls, 1);
    assert.equal(harness.requests.length, 1);
    assert.deepEqual(posted.body.object.params, {});
    harness.applyDecodedEnvelope(harness.provider, {
        id: posted.id,
        kind: "error",
        name: "connect",
        error: {code: 4001, message: "Canceled"},
    });
    await rejected;
});

test("queued Solana generated payloads reuse normalized data without extra hooks", async () => {
    const cases = [
        {method: "signTransaction", params: {transaction: legacyTransaction(1).transaction}, expected: {message: "2"}},
        {method: "signTransaction", params: {message: "2"}, expected: {message: "2"}},
        {method: "signAllTransactions", params: {transactions: [legacyTransaction(1).transaction]}, expected: {messages: ["2"]}},
        {method: "signAllTransactions", params: {messages: ["2"]}, expected: {messages: ["2"]}},
        {method: "signAndSendTransaction", params: {transaction: "2", options: {skipPreflight: false}}, expected: {transaction: "2", options: {skipPreflight: false}}},
    ];
    for (const {method, params, expected} of cases) {
        const authorization = {
            isConnected: true,
            publicKey: firstSolanaKey,
            workerRevision: 1,
        };
        const harness = solanaHarness(authorization);
        const pending = harness.provider.request({method, params});
        const rejected = assert.rejects(pending, error => error.code === 4001);
        if (params.options) { params.options.skipPreflight = true; }
        if (params.messages) { params.messages[0] = "3"; }
        const objectPrototype = vm.runInContext("Object.prototype", harness.context);
        const arrayPrototype = vm.runInContext("Array.prototype", harness.context);
        let objectCalls = 0;
        let setterCalls = 0;
        objectPrototype.toJSON = function () { objectCalls += 1; return this; };
        arrayPrototype.toJSON = () => { throw new Error("Array prototype called"); };
        for (const field of ["id", "method", "params"]) {
            Object.defineProperty(objectPrototype, field, {
                configurable: true,
                set() { setterCalls += 1; },
            });
        }
        try {
            applySolanaConfiguration(harness, {
                publicKey: authorization.publicKey,
                isConnected: authorization.isConnected,
                workerRevision: authorization.workerRevision,
            });
            assert.equal(harness.requests.length, 1, method);
            assert.deepEqual(normalized(harness.requests[0].body.object.params), expected);
            assert.equal(objectCalls, 0, "The final wire envelope never invokes JSON hooks");
            assert.equal(setterCalls, 0, "Envelope fields never invoke inherited setters");
        } finally {
            delete objectPrototype.toJSON;
            delete arrayPrototype.toJSON;
            for (const field of ["id", "method", "params"]) {
                delete objectPrototype[field];
            }
        }
        harness.applyDecodedEnvelope(harness.provider, {
            id: harness.requests[0].id,
            kind: "error",
            name: method,
            error: {code: 4001, message: "Canceled"},
        });
        await rejected;
    }
});

test("Solana send options remain private when generated fields have inherited setters", async () => {
    for (const field of ["transaction", "message", "options"]) {
        const authorization = {
            isConnected: true,
            publicKey: firstSolanaKey,
            workerRevision: 1,
        };
        const harness = solanaHarness(authorization);
        const prototype = vm.runInContext("Object.prototype", harness.context);
        let captured;
        Object.defineProperty(prototype, field, {
            configurable: true,
            set(value) {
                captured = this;
                Object.defineProperty(this, field, {
                    configurable: true,
                    enumerable: true,
                    value,
                    writable: true,
                });
            },
        });
        const params = {
            [field === "message" ? "message" : "transaction"]: "2",
            options: {skipPreflight: false},
        };
        let pending;
        try {
            pending = harness.provider.request({method: "signAndSendTransaction", params});
        } finally {
            delete prototype[field];
        }
        const rejected = assert.rejects(pending, error => error.code === 4001);
        if (captured?.options) { captured.options.skipPreflight = true; }
        applySolanaConfiguration(harness, {
            publicKey: authorization.publicKey,
            isConnected: authorization.isConnected,
            workerRevision: authorization.workerRevision,
        });
        assert.equal(harness.requests[0].body.object.params.options.skipPreflight, false, field);
        harness.applyDecodedEnvelope(harness.provider, {
            id: harness.requests[0].id,
            kind: "error",
            name: "signAndSendTransaction",
            error: {code: 4001, message: "Canceled"},
        });
        await rejected;
    }
});

test("Solana batch construction preserves messages with inherited array accessors", async () => {
    for (const objectTransactions of [false, true]) {
        const authorization = {
            isConnected: true,
            publicKey: firstSolanaKey,
            workerRevision: 1,
        };
        const harness = solanaHarness(authorization);
        const prototype = vm.runInContext("Array.prototype", harness.context);
        const assigned = new WeakMap;
        Object.defineProperty(prototype, "0", {
            configurable: true,
            get() { return assigned.get(this); },
            set(value) {
                assigned.set(this, value);
                if (this.length === 0) { this.length = 1; }
            },
        });
        let pending;
        try {
            pending = harness.provider.request({
                method: "signAllTransactions",
                params: objectTransactions
                    ? {transactions: [legacyTransaction(1).transaction]}
                    : {messages: ["2"]},
            });
            applySolanaConfiguration(harness, {
                publicKey: authorization.publicKey,
                isConnected: authorization.isConnected,
                workerRevision: authorization.workerRevision,
            });
            assert.deepEqual(structuredClone(harness.requests[0].body.object.params), {
                messages: ["2"],
            });
        } finally {
            delete prototype["0"];
        }
        const rejected = assert.rejects(pending, error => error.code === 4001);
        harness.applyDecodedEnvelope(harness.provider, {
            id: harness.requests[0].id,
            kind: "error",
            name: "signAllTransactions",
            error: {code: 4001, message: "Canceled"},
        });
        await rejected;
    }
});

test("Solana rejects adapter messages corrupted by inherited setters before dispatch", async () => {
    for (const versioned of [false, true]) {
        for (const field of ["message", "signatures"]) {
            const authorization = {
                isConnected: true,
                publicKey: firstSolanaKey,
                workerRevision: 1,
            };
            const harness = solanaHarness(authorization);
            const transaction = versioned
                ? versionedTransaction(1).transaction
                : legacyTransaction(1).transaction;
            const injected = {value: 1};
            const prototype = vm.runInContext("Object.prototype", harness.context);
            Object.defineProperty(prototype, field, {
                configurable: true,
                set(value) {
                    Object.defineProperty(this, field, {
                        configurable: true,
                        enumerable: true,
                        value: field === "message" ? injected : value,
                        writable: true,
                    });
                    if (field === "signatures") { this.message = injected; }
                },
            });
            let pending;
            try {
                pending = harness.provider.request({method: "signTransaction", params: {transaction}});
            } finally {
                delete prototype[field];
            }
            await assert.rejects(pending, error => error.code === 4200);
            applySolanaConfiguration(harness, {
                publicKey: authorization.publicKey,
                isConnected: authorization.isConnected,
                workerRevision: authorization.workerRevision,
            });
            assert.equal(harness.requests.length, 0);
        }
    }
});

test("Solana rejects non-string encoder results before dispatch", async () => {
    const cases = [
        {method: "signTransaction", params: {message: new Uint8Array([0])}},
        {method: "signTransaction", params: {transaction: legacyTransaction(0).transaction}},
        {method: "signAllTransactions", params: {messages: [new Uint8Array([0])]}},
        {method: "signAndSendTransaction", params: {transaction: new Uint8Array([0])}},
        {method: "signAndSendTransaction", params: {message: new Uint8Array([0])}},
    ];
    for (const {method, params} of cases) {
        const authorization = {
            isConnected: true,
            publicKey: firstSolanaKey,
            workerRevision: 1,
        };
        const harness = solanaHarness(authorization);
        const prototype = vm.runInContext("String.prototype", harness.context);
        const original = prototype.repeat;
        const injected = {value: 1};
        prototype.repeat = function (count) {
            return String(this) === "1" ? injected : original.call(this, count);
        };
        let pending;
        try {
            pending = harness.provider.request({method, params});
        } finally {
            prototype.repeat = original;
        }
        await assert.rejects(pending, error => error.code === 4200);
        applySolanaConfiguration(harness, {
            publicKey: authorization.publicKey,
            isConnected: authorization.isConnected,
            workerRevision: authorization.workerRevision,
        });
        assert.equal(harness.requests.length, 0, method);
    }
});

test("Solana rejects a falsy transaction encoding instead of falling back to a message", async () => {
    for (const encoded of [0, false, null, undefined]) {
        const authorization = {
            isConnected: true,
            publicKey: firstSolanaKey,
            workerRevision: 1,
        };
        const harness = solanaHarness(authorization);
        const transaction = legacyTransaction(1).transaction;
        transaction.serialize = () => new Uint8Array([0]);
        const prototype = vm.runInContext("String.prototype", harness.context);
        const original = prototype.repeat;
        prototype.repeat = function (count) {
            return String(this) === "1" && count === 1
                ? encoded
                : original.call(this, count);
        };
        let pending;
        try {
            pending = harness.provider.request({
                method: "signAndSendTransaction",
                params: {transaction, message: "2"},
            });
        } finally {
            prototype.repeat = original;
        }
        await assert.rejects(pending, error => error.code === 4200);
        applySolanaConfiguration(harness, {
            publicKey: authorization.publicKey,
            isConnected: authorization.isConnected,
            workerRevision: authorization.workerRevision,
        });
        assert.equal(harness.requests.length, 0);
    }
});

test("Wallet Standard rejects non-string encoder results before dispatch", async () => {
    for (const method of ["standardSignTransaction", "standardSignAndSendTransaction"]) {
        const authorization = {
            isConnected: true,
            publicKey: firstSolanaKey,
            workerRevision: 1,
        };
        const harness = solanaHarness(authorization);
        applySolanaConfiguration(harness, {
            publicKey: authorization.publicKey,
            isConnected: authorization.isConnected,
            workerRevision: authorization.workerRevision,
        });
        const account = harness.standardProvider.standardAccounts()[0];
        harness.provider.preparedStandardTransaction = () => ({
            messageBytes: new Uint8Array([0]),
            signatureOffset: 1,
            transactionBytes: new Uint8Array(66),
        });
        const prototype = vm.runInContext("String.prototype", harness.context);
        const original = prototype.repeat;
        prototype.repeat = function (count) {
            return String(this) === "1" ? {value: 1} : original.call(this, count);
        };
        let pending;
        try {
            pending = harness.provider[method]({
                account,
                chain: "solana:mainnet",
                transaction: new Uint8Array([0]),
            });
        } finally {
            prototype.repeat = original;
        }
        await assert.rejects(pending, error => error.code === 4200);
        assert.equal(harness.requests.length, 0, method);
    }
});

test("Solana settles a committed signature after later authorization drift", async () => {
    const harness = solanaHarness({
        isConnected: true,
        publicKey: firstSolanaKey,
        workerRevision: 1,
    });
    applySolanaConfiguration(harness, {
        isConnected: true,
        publicKey: firstSolanaKey,
        workerRevision: 1,
    });
    const signing = harness.provider.signMessage(new Uint8Array([1]));
    const request = harness.requests.at(-1);
    applySolanaConfiguration(harness, {
        isConnected: true,
        publicKey: secondSolanaKey,
        workerRevision: 2,
    });
    harness.applyDecodedEnvelope(harness.provider, {
        approvalCommitted: true,
        id: request.id,
        kind: "result",
        name: "signMessage",
        result: validSignature,
    });

    const result = await signing;
    assert.equal(result.signature.length, 64);
    assert.equal(result.publicKey.toString(), firstSolanaKey);
    assert.equal(harness.provider.publicKey.toString(), secondSolanaKey);
});

test("Solana applies a committed transaction signature after authorization drift", async () => {
    const harness = solanaHarness({
        isConnected: true,
        publicKey: firstSolanaKey,
        workerRevision: 1,
    });
    applySolanaConfiguration(harness, {
        isConnected: true,
        publicKey: firstSolanaKey,
        workerRevision: 1,
    });
    const transaction = legacyTransaction(1);
    const signing = harness.provider.signTransaction(transaction.transaction);
    const request = harness.requests.at(-1);
    applySolanaConfiguration(harness, {
        isConnected: true,
        publicKey: secondSolanaKey,
        workerRevision: 2,
    });
    harness.applyDecodedEnvelope(harness.provider, {
        approvalCommitted: true,
        id: request.id,
        kind: "result",
        name: "signTransaction",
        result: validSignature,
    });

    assert.equal(await signing, transaction.transaction);
    assert.equal(transaction.entry.signature.length, 64);
    assert.equal(harness.provider.publicKey.toString(), secondSolanaKey);
});

test("Wallet Standard settles committed single-item signing after authorization drift", async () => {
    for (const variant of ["message", "transaction", "send"]) {
        const harness = solanaHarness({
            isConnected: true,
            publicKey: firstSolanaKey,
            workerRevision: 1,
        });
        applySolanaConfiguration(harness, {
            isConnected: true,
            publicKey: firstSolanaKey,
            workerRevision: 1,
        });
        const account = harness.standardProvider.standardAccounts()[0];
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
            isConnected: true,
            publicKey: secondSolanaKey,
            workerRevision: 2,
        });
        harness.applyDecodedEnvelope(harness.provider, {
            approvalCommitted: true,
            id: request.id,
            kind: "result",
            name: request.name,
            result: validSignature,
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
        isConnected: false,
        publicKey: null,
        workerRevision: 0,
    });
    const connecting = harness.provider.connect();
    const request = harness.requests.at(-1);
    applySolanaConfiguration(harness, {
        isConnected: true,
        publicKey: secondSolanaKey,
        workerRevision: 1,
    });
    harness.applyDecodedEnvelope(harness.provider, {
        approvalCommitted: true,
        id: request.id,
        kind: "result",
        name: "connect",
        result: {publicKey: firstSolanaKey},
    });

    assert.equal((await connecting).publicKey.toString(), firstSolanaKey);
    assert.equal(harness.provider.publicKey.toString(), secondSolanaKey);
});

test("Wallet Standard committed connect returns current authorization", async () => {
    for (const currentPublicKey of [secondSolanaKey, null]) {
        const harness = solanaHarness();
        applySolanaConfiguration(harness);
        const connecting = harness.standardProvider.standardConnect();
        const request = harness.requests.at(-1);
        if (currentPublicKey) {
            applySolanaConfiguration(harness, {
                isConnected: true,
                publicKey: currentPublicKey,
                workerRevision: 1,
            });
        } else {
            applySolanaConfiguration(harness);
        }
        harness.applyDecodedEnvelope(harness.provider, {
            approvalCommitted: true,
            id: request.id,
            kind: "result",
            name: "connect",
            result: {publicKey: firstSolanaKey},
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
            isConnected: true,
            publicKey: firstSolanaKey,
            workerRevision: 1,
        });
        applySolanaConfiguration(harness, {
            isConnected: true,
            publicKey: firstSolanaKey,
            workerRevision: 1,
        });
        const signed = harness.provider.signTransaction(transaction.transaction);
        harness.applyDecodedEnvelope(harness.provider, {
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

test("Solana preserves SDK transaction identity, cosignatures, and serializable signed bytes", async () => {
    const wallet = solanaSDK.Keypair.fromSeed(new Uint8Array(32).fill(1));
    const cosigner = solanaSDK.Keypair.fromSeed(new Uint8Array(32).fill(2));
    for (const method of ["signTransaction", "signAllTransactions"]) {
        const harness = connectedSolanaHarness(wallet.publicKey.toBase58(), {Uint8Array});
        const fixtures = ["legacy", "v0", "versionedLegacy"].map(kind =>
            sdkTransactionFixture(kind, wallet, cosigner)
        );
        const batches = method === "signTransaction"
            ? fixtures.map(fixture => [fixture])
            : [fixtures];
        for (const batch of batches) {
            const isBatch = method === "signAllTransactions";
            const signing = harness.provider[method](isBatch
                ? batch.map(fixture => fixture.transaction)
                : batch[0].transaction);
            harness.applyDecodedEnvelope(harness.provider, {
                id: harness.requests.at(-1).id,
                name: method,
                kind: "result",
                ...(isBatch
                    ? {result: batch.map(fixture => fixture.response)}
                    : {result: batch[0].response}),
            });
            const result = await signing;
            const signedTransactions = isBatch ? result : [result];
            assert.equal(signedTransactions.length, batch.length);
            for (const [index, fixture] of batch.entries()) {
                const transaction = signedTransactions[index];
                assert.equal(transaction, fixture.transaction);
                assert.equal(transaction.signatures, fixture.signatures);
                const cosignature = fixture.legacy
                    ? transaction.signatures[0].signature
                    : transaction.signatures[0];
                assert.equal(cosignature, fixture.cosignature);
                assert.deepEqual(Buffer.from(cosignature), fixture.cosignatureBytes);
                if (fixture.legacy) {
                    assert.equal(transaction.signatures[1], fixture.signerEntry);
                    assert.equal(transaction.verifySignatures(), true);
                }
                const bytes = Buffer.from(transaction.serialize());
                assert.deepEqual(bytes, fixture.expectedBytes);
                assert.deepEqual(Buffer.from(fixture.deserialize(bytes).serialize()), bytes);
            }
        }
    }
});

test("Solana response message validation scales linearly with batch size", async () => {
    for (const makeTransaction of [legacyTransaction, versionedTransaction]) {
        for (const size of [1, 8, 64]) {
            const harness = connectedSolanaHarness();
            let serializations = 0;
            const transactions = Array.from({length: size}, (_, index) => {
                const fixture = makeTransaction(index + 1);
                const owner = fixture.entry ? fixture.transaction : fixture.transaction.message;
                const method = fixture.entry ? "serializeMessage" : "serialize";
                const serialize = owner[method];
                owner[method] = function () {
                    serializations += 1;
                    return serialize.call(this);
                };
                return fixture.transaction;
            });
            const signing = harness.provider.signAllTransactions(transactions);
            const beforeResponse = serializations;
            harness.applyDecodedEnvelope(harness.provider, {
                id: harness.requests[0].id,
                kind: "result",
                name: "signAllTransactions",
                result: transactions.map(() => validSignature),
            });
            const result = await signing;
            assert.equal(result.length, size);
            for (const [index, transaction] of transactions.entries()) {
                assert.equal(result[index], transaction);
            }
            assert.ok(serializations - beforeResponse <= 2 * size,
                `${size} transactions used ${serializations - beforeResponse} response serializations`);
        }
    }
});

test("Solana supports legacy messages wrapped in versioned transactions", async () => {
    class LegacyMessage {
        constructor() {
            this.header = {numRequiredSignatures: 1};
            this.accountKeys = [publicKey()];
        }

        get staticAccountKeys() { return this.accountKeys; }
        serialize() { return new Uint8Array([1]); }
    }

    for (const method of ["signTransaction", "signAllTransactions", "signAndSendTransaction"]) {
        const harness = solanaHarness();
        applySolanaConfiguration(harness, {
            isConnected: true,
            publicKey: firstSolanaKey,
            workerRevision: 1,
        });
        const transaction = {
            message: new LegacyMessage(),
            signatures: [new Uint8Array(64).fill(7)],
            serialize() { return new Uint8Array([2]); },
        };
        const isBatch = method === "signAllTransactions";
        const signed = harness.provider[method](isBatch ? [transaction] : transaction);
        signed.catch(() => {});
        assert.equal(harness.requests.length, 1, method);
        harness.applyDecodedEnvelope(harness.provider, {
            id: harness.requests[0].id,
            kind: "result",
            name: method,
            ...(isBatch ? {result: [validSignature]} : {result: validSignature}),
        });
        const result = await signed;
        if (method === "signAndSendTransaction") {
            assert.equal(result.signature, validSignature);
        } else {
            assert.equal(isBatch ? result[0] : result, transaction);
            assert.deepEqual(Array.from(transaction.signatures[0]), new Array(64).fill(0));
        }
    }
});

test("Solana rejects replacement of a versioned transaction message", async () => {
    const harness = solanaHarness({
        isConnected: true,
        publicKey: firstSolanaKey,
        workerRevision: 1,
    });
    applySolanaConfiguration(harness, {
        isConnected: true,
        publicKey: firstSolanaKey,
        workerRevision: 1,
    });
    const transaction = versionedTransaction(1);
    const replacement = versionedTransaction(2);
    const request = harness.provider.signTransaction(transaction.transaction);
    transaction.transaction.message = replacement.transaction.message;
    harness.applyDecodedEnvelope(harness.provider, {
        id: harness.requests[0].id,
        kind: "result",
        name: "signTransaction",
        result: validSignature,
    });
    await assert.rejects(request, error => error.code === 4200);
    assert.deepEqual([...transaction.signatures[0]], new Array(64).fill(0));

    const reentrant = versionedTransaction(1);
    const reentrantReplacement = versionedTransaction(2);
    let replaceMessage = false;
    reentrant.transaction.message.serialize = () => {
        if (replaceMessage) {
            replaceMessage = false;
            reentrant.transaction.message =
                reentrantReplacement.transaction.message;
        }
        return new Uint8Array([1]);
    };
    const reentrantRequest = harness.provider.signTransaction(
        reentrant.transaction
    );
    replaceMessage = true;
    harness.applyDecodedEnvelope(harness.provider, {
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
            isConnected: true,
            publicKey: firstSolanaKey,
            workerRevision: 1,
        });
        applySolanaConfiguration(harness, {
            isConnected: true,
            publicKey: firstSolanaKey,
            workerRevision: 1,
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
        harness.applyDecodedEnvelope(harness.provider, {
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
        isConnected: true,
        publicKey: firstSolanaKey,
        workerRevision: 1,
    });
    applySolanaConfiguration(harness, {
        isConnected: true,
        publicKey: firstSolanaKey,
        workerRevision: 1,
    });
    const transaction = legacyTransaction(1);
    let changeAuthorization = false;
    transaction.transaction.serializeMessage = () => {
        if (changeAuthorization && transaction.entry.signature !== null) {
            changeAuthorization = false;
            applySolanaConfiguration(harness, {
                isConnected: true,
                publicKey: secondSolanaKey,
                workerRevision: 2,
            });
        }
        return new Uint8Array([1]);
    };
    const request = harness.provider.signTransaction(transaction.transaction);
    changeAuthorization = true;
    harness.applyDecodedEnvelope(harness.provider, {
        id: harness.requests[0].id,
        kind: "result",
        name: "signTransaction",
        result: validSignature,
    });
    await assert.rejects(request, error => error.code === 4900);
    assert.deepEqual([...transaction.entry.signature], new Array(64).fill(0));
});

test("Solana rejects invalid signatures, mutation, custom shapes, and oversized batches", async () => {
    const harness = solanaHarness({
        isConnected: true,
        publicKey: firstSolanaKey,
        workerRevision: 1,
    });
    applySolanaConfiguration(harness, {
        isConnected: true,
        publicKey: firstSolanaKey,
        workerRevision: 1,
    });
    const mutable = legacyTransaction(1);
    let byte = 1;
    mutable.transaction.serializeMessage = () => new Uint8Array([byte]);
    const changed = harness.provider.signTransaction(mutable.transaction);
    byte = 2;
    harness.applyDecodedEnvelope(harness.provider, {
        id: harness.requests[0].id,
        kind: "result",
        name: "signTransaction",
        result: validSignature,
    });
    await assert.rejects(changed, error => error.code === 4200);
    assert.equal(mutable.entry.signature, null);

    const invalid = legacyTransaction(3);
    const invalidSignature = harness.provider.signTransaction(invalid.transaction);
    harness.applyDecodedEnvelope(harness.provider, {
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

test("Solana preserves recreated signature slots for subsequent signing", async () => {
    for (const makeTransaction of [legacyTransaction, versionedTransaction]) {
        for (const enumerable of [false, true]) {
            const harness = connectedSolanaHarness();
            const first = makeTransaction(1);
            const second = makeTransaction(2);
            const target = first.entry || first.signatures;
            const property = first.entry ? "signature" : "0";
            Object.defineProperty(target, property, {enumerable});
            const owner = second.entry ? second.transaction : second.transaction.message;
            const method = second.entry ? "serializeMessage" : "serialize";
            let deleteSlot = false;
            owner[method] = () => {
                if (deleteSlot) {
                    deleteSlot = false;
                    delete target[property];
                }
                return new Uint8Array([2]);
            };
            const signing = harness.provider.signAllTransactions([
                first.transaction, second.transaction,
            ]);
            deleteSlot = true;
            harness.applyDecodedEnvelope(harness.provider, {
                id: harness.requests[0].id,
                kind: "result",
                name: "signAllTransactions",
                result: [validSignature, validSignature],
            });
            const signed = await signing;
            assert.equal(signed[0], first.transaction);
            const descriptor = Object.getOwnPropertyDescriptor(target, property);
            assert.equal(descriptor.writable, true);
            assert.equal(descriptor.enumerable, enumerable);
            assert.equal(descriptor.configurable, true);

            const nextSigning = harness.provider.signTransaction(first.transaction);
            harness.applyDecodedEnvelope(harness.provider, {
                id: harness.requests[1].id,
                kind: "result",
                name: "signTransaction",
                result: validSignature,
            });
            assert.equal(await nextSigning, first.transaction);
        }
    }
});

test("Solana stops failed signature application without undoing completed writes", async () => {
    for (const makeTransaction of [legacyTransaction, versionedTransaction]) {
        for (const failAfterWrite of [false, true]) {
            const harness = connectedSolanaHarness();
            const fixtures = [1, 2, 3].map(byte => makeTransaction(byte));
            const originals = [];
            const attempted = [];
            for (const [index, fixture] of fixtures.entries()) {
                const target = fixture.entry || fixture.signatures;
                const property = fixture.entry ? "signature" : "0";
                const original = Object.getOwnPropertyDescriptor(target, property);
                originals.push({target, property, original});
                const proxy = new Proxy(target, {
                    defineProperty(object, name, descriptor) {
                        if (name === property) {
                            attempted.push(index);
                            if (index === 1) {
                                if (failAfterWrite) {
                                    Reflect.defineProperty(object, name, descriptor);
                                }
                                throw new Error("apply failed");
                            }
                        }
                        return Reflect.defineProperty(object, name, descriptor);
                    },
                });
                if (fixture.entry) {
                    fixture.transaction.signatures[0] = proxy;
                } else {
                    fixture.transaction.signatures = proxy;
                }
            }
            const signing = harness.provider.signAllTransactions(
                fixtures.map(fixture => fixture.transaction)
            );
            harness.applyDecodedEnvelope(harness.provider, {
                id: harness.requests[0].id,
                kind: "result",
                name: "signAllTransactions",
                result: fixtures.map(() => validSignature),
            });
            await assert.rejects(signing, /apply failed/);
            assert.deepEqual(attempted, [0, 1]);
            for (const [index, {target, property, original}] of originals.entries()) {
                const current = Object.getOwnPropertyDescriptor(target, property);
                if (index === 0 || index === 1 && failAfterWrite) {
                    assert.notEqual(current.value, original.value);
                    assert.deepEqual([...current.value], new Array(64).fill(0));
                    assert.equal(current.writable, original.writable);
                    assert.equal(current.enumerable, original.enumerable);
                    assert.equal(current.configurable, original.configurable);
                } else {
                    assert.deepEqual(current, original);
                }
            }
        }
    }
});

test("Solana rejects a later batch setter that mutates an earlier message", async () => {
    const harness = solanaHarness({
        isConnected: true,
        publicKey: firstSolanaKey,
        workerRevision: 1,
    });
    applySolanaConfiguration(harness, {
        isConnected: true,
        publicKey: firstSolanaKey,
        workerRevision: 1,
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
    harness.applyDecodedEnvelope(harness.provider, {
        id: harness.requests[0].id,
        kind: "result",
        name: "signAllTransactions",
        result: [validSignature, validSignature],
    });
    await assert.rejects(request, error => error.code === 4200);
    assert.deepEqual([...first.entry.signature], new Array(64).fill(0));
    assert.deepEqual([...secondTarget.signature], new Array(64).fill(0));
});

test("Solana rejects duplicate or aliased signer targets before writing", async () => {
    for (const makeTransaction of [legacyTransaction, versionedTransaction]) {
        for (const alias of ["transaction", "slot"]) {
            const harness = connectedSolanaHarness();
            const first = makeTransaction(1);
            const second = alias === "transaction" ? first : makeTransaction(2);
            if (alias === "slot") {
                if (first.entry) {
                    second.transaction.signatures[0] = first.entry;
                } else {
                    second.transaction.signatures = first.signatures;
                }
            }
            const signatures = first.transaction.signatures;
            const original = first.entry ? first.entry.signature : signatures[0];
            const signing = harness.provider.signAllTransactions([
                first.transaction,
                second.transaction,
            ]);
            harness.applyDecodedEnvelope(harness.provider, {
                id: harness.requests[0].id,
                kind: "result",
                name: "signAllTransactions",
                result: [validSignature, validSignature],
            });
            await assert.rejects(signing, error => error.code === 4200);
            assert.equal(first.transaction.signatures, signatures);
            assert.equal(first.entry ? first.entry.signature : signatures[0],
                original);
        }
    }
});

test("Solana preflight leaves a caller-replaced signature array untouched", async () => {
    for (const makeTransaction of [legacyTransaction, versionedTransaction]) {
        const harness = connectedSolanaHarness();
        const original = makeTransaction(1);
        const signing = harness.provider.signTransaction(original.transaction);
        const replacementBytes = new Uint8Array(64).fill(9);
        const replacementSlot = original.entry
            ? {publicKey: publicKey(), signature: replacementBytes}
            : replacementBytes;
        const replacementSignatures = [replacementSlot];
        original.transaction.signatures = replacementSignatures;
        harness.applyDecodedEnvelope(harness.provider, {
            id: harness.requests[0].id,
            kind: "result",
            name: "signTransaction",
            result: validSignature,
        });
        await assert.rejects(signing, error => error.code === 4200);
        assert.equal(original.transaction.signatures, replacementSignatures);
        assert.equal(replacementSignatures[0], replacementSlot);
        assert.deepEqual([...replacementBytes], new Array(64).fill(9));
    }
});

test("Solana preflights a whole batch before applying signatures", async () => {
    const harness = solanaHarness({
        isConnected: true,
        publicKey: firstSolanaKey,
        workerRevision: 1,
    });
    applySolanaConfiguration(harness, {
        isConnected: true,
        publicKey: firstSolanaKey,
        workerRevision: 1,
    });
    const first = legacyTransaction(1);
    const second = legacyTransaction(2);
    const request = harness.provider.signAllTransactions([
        first.transaction,
        second.transaction,
    ]);
    harness.applyDecodedEnvelope(harness.provider, {
        id: harness.requests[0].id,
        kind: "result",
        name: "signAllTransactions",
        result: [validSignature, "1".repeat(63)],
    });
    await assert.rejects(request, error => error.code === 4200);
    assert.equal(first.entry.signature, null);
    assert.equal(second.entry.signature, null);
});

test("Solana preflights every transaction and signer slot before batch writes", async () => {
    for (const makeTransaction of [legacyTransaction, versionedTransaction]) {
        for (const failure of ["message", "signer", "readonly", "signature"]) {
            const harness = connectedSolanaHarness();
            const first = makeTransaction(1);
            const second = makeTransaction(2);
            let secondByte = 2;
            if (second.entry) {
                second.transaction.serializeMessage = () => new Uint8Array([secondByte]);
            } else {
                second.transaction.message.serialize = () => new Uint8Array([secondByte]);
            }
            const original = first.entry ? first.entry.signature : first.signatures[0];
            const signing = harness.provider.signAllTransactions([
                first.transaction,
                second.transaction,
            ]);
            if (failure === "message") {
                secondByte = 3;
            } else if (failure === "signer") {
                if (second.entry) {
                    second.entry.publicKey = publicKey(secondSolanaKey);
                } else {
                    second.transaction.message.staticAccountKeys[0] = publicKey(secondSolanaKey);
                }
            } else if (failure === "readonly") {
                Object.defineProperty(second.entry || second.signatures,
                    second.entry ? "signature" : "0", {writable: false});
            }
            harness.applyDecodedEnvelope(harness.provider, {
                id: harness.requests[0].id,
                kind: "result",
                name: "signAllTransactions",
                result: [validSignature, failure === "signature" ? "1".repeat(63) : validSignature],
            });
            await assert.rejects(signing, error => error.code === 4200);
            assert.equal(first.entry ? first.entry.signature : first.signatures[0], original);
        }
    }
});

test("Solana rechecks operation currentness around response callbacks", async () => {
    for (const phase of ["preflight", "write", "final"]) {
        for (const change of ["account", "retire"]) {
            const harness = connectedSolanaHarness();
            const fixture = legacyTransaction(1);
            let armed = false;
            const invalidate = () => {
                if (!armed) { return; }
                armed = false;
                if (change === "retire") {
                    harness.Solana.retire(harness.provider);
                } else {
                    applySolanaConfiguration(harness, {
                        isConnected: true,
                        publicKey: secondSolanaKey,
                        workerRevision: 2,
                    });
                }
            };
            if (phase === "preflight") {
                fixture.entry.publicKey.toString = () => {
                    invalidate();
                    return firstSolanaKey;
                };
            } else if (phase === "write") {
                fixture.transaction.signatures[0] = new Proxy(fixture.entry, {
                    defineProperty(target, name, descriptor) {
                        const applied = Reflect.defineProperty(target, name, descriptor);
                        if (name === "signature" && descriptor.value !== null) {
                            invalidate();
                        }
                        return applied;
                    },
                });
            } else {
                fixture.transaction.serializeMessage = () => {
                    if (fixture.entry.signature !== null) { invalidate(); }
                    return new Uint8Array([1]);
                };
            }
            const signing = harness.provider.signTransaction(fixture.transaction);
            armed = true;
            harness.applyDecodedEnvelope(harness.provider, {
                id: harness.requests[0].id,
                kind: "result",
                name: "signTransaction",
                result: validSignature,
            });
            await assert.rejects(signing, error => error.code === 4900);
            if (phase === "preflight") {
                assert.equal(fixture.entry.signature, null);
            } else {
                assert.deepEqual([...fixture.entry.signature], new Array(64).fill(0));
            }
        }
    }
});

for (const method of ["signMessage", "signTransaction", "signAndSendTransaction"]) {
    test(`Wallet Standard ${method} preserves queued signing authorization`, async () => {
        const wallet = solanaSDK.Keypair.fromSeed(new Uint8Array(32).fill(1));
        const cosigner = solanaSDK.Keypair.fromSeed(new Uint8Array(32).fill(2));
        const fixture = sdkTransactionFixture("legacy", wallet, cosigner);
        const authorization = {
            isConnected: true,
            publicKey: wallet.publicKey.toBase58(),
            workerRevision: 1,
        };
        for (const change of ["none", "account", "revision"]) {
            const harness = solanaHarness(authorization);
            const account = harness.wallet.accounts[0];
            const input = method === "signMessage"
                ? {account, message: new Uint8Array([1, 2, 3])}
                : {
                    account,
                    chain: "solana:mainnet",
                    transaction: new Uint8Array(fixture.transaction.serialize({
                        requireAllSignatures: false,
                        verifySignatures: false,
                    })),
                };
            const pending = harness.wallet.features[`solana:${method}`][method](input);
            assert.equal(harness.requests.length, 0);
            const rejected = change !== "account" ? null : assert.rejects(
                pending,
                error => error.code === 4100
            );
            applySolanaConfiguration(harness, {
                isConnected: true,
                publicKey: change === "account"
                    ? cosigner.publicKey.toBase58()
                    : authorization.publicKey,
                workerRevision: change === "none" ? 1 : 2,
            });
            for (let turn = 0; turn < 5; turn++) { await Promise.resolve(); }
            if (rejected) {
                assert.equal(harness.requests.length, 0);
                await rejected;
                continue;
            }
            assert.equal(harness.requests.length, 1);
            const request = harness.requests[0];
            assert.equal(request.body.publicKey, account.address);
            harness.applyDecodedEnvelope(harness.provider, {
                id: request.id,
                kind: "result",
                name: request.name,
                result: fixture.response,
            });
            const [result] = await pending;
            if (method === "signTransaction") {
                assert.deepEqual(Buffer.from(result.signedTransaction), fixture.expectedBytes);
            } else {
                assert.equal(result.signature.length, 64);
            }
        }
    });
}

test("Solana signing keeps its canonical signer when the public key wrapper changes", async () => {
    for (const behavior of ["mutate", "throw"]) {
        for (const timing of ["before", "pending"]) {
            for (const method of ["signMessage", "signTransaction"]) {
                const harness = connectedSolanaHarness();
                const key = harness.provider.publicKey;
                const fixture = legacyTransaction(1);
                let reads;
                if (timing === "before") {
                    reads = overrideProviderPublicKey(key, behavior);
                }
                const pending = method === "signMessage"
                    ? harness.provider.signMessage(new Uint8Array([1]))
                    : harness.provider.signTransaction(fixture.transaction);
                assert.equal(harness.requests.length, 1);
                const request = harness.requests[0];
                assert.equal(request.body.publicKey, firstSolanaKey);
                if (timing === "pending") {
                    reads = overrideProviderPublicKey(key, behavior);
                }
                harness.applyDecodedEnvelope(harness.provider, {
                    id: request.id,
                    kind: "result",
                    name: method,
                    result: validSignature,
                });
                const result = await pending;
                if (method === "signMessage") {
                    assert.equal(result.publicKey.toString(), firstSolanaKey);
                    assert.equal(result.signature.length, 64);
                } else {
                    assert.equal(result, fixture.transaction);
                    assert.deepEqual(Array.from(fixture.entry.signature), new Array(64).fill(0));
                }
                assert.equal(harness.provider.publicKey, key);
                assert.equal(reads(), 0);
            }
        }
    }
});

test("Wallet Standard signing ignores mutable provider public key identity and byte methods", async () => {
    const wallet = solanaSDK.Keypair.fromSeed(new Uint8Array(32).fill(1));
    const cosigner = solanaSDK.Keypair.fromSeed(new Uint8Array(32).fill(2));
    for (const behavior of ["mutate", "throw"]) {
        for (const method of ["signMessage", "signTransaction", "signAndSendTransaction"]) {
            const fixture = sdkTransactionFixture("legacy", wallet, cosigner);
            const address = wallet.publicKey.toBase58();
            const harness = connectedSolanaHarness(address);
            const account = harness.wallet.accounts[0];
            const key = harness.provider.publicKey;
            const reads = overrideProviderPublicKey(key, behavior);
            const input = method === "signMessage"
                ? {account, message: new Uint8Array([1, 2, 3])}
                : {
                    account,
                    chain: "solana:mainnet",
                    transaction: new Uint8Array(fixture.transaction.serialize({
                        requireAllSignatures: false,
                        verifySignatures: false,
                    })),
                };
            const pending = harness.wallet.features[`solana:${method}`][method](input);
            assert.equal(harness.requests.length, 1);
            const request = harness.requests[0];
            assert.equal(request.body.publicKey, address);
            harness.applyDecodedEnvelope(harness.provider, {
                id: request.id,
                kind: "result",
                name: method,
                result: fixture.response,
            });
            const [result] = await pending;
            if (method === "signTransaction") {
                assert.deepEqual(Buffer.from(result.signedTransaction), fixture.expectedBytes);
            } else {
                assert.equal(result.signature.length, 64);
            }
            assert.equal(harness.wallet.accounts[0], account);
            assert.equal(account.address, address);
            assert.equal(harness.provider.publicKey, key);
            assert.equal(reads(), 0);
        }
    }
});

test("Wallet Standard signing preflights and caps every input", async () => {
    const harness = solanaHarness({
        isConnected: true,
        publicKey: firstSolanaKey,
        workerRevision: 1,
    });
    applySolanaConfiguration(harness, {
        isConnected: true,
        publicKey: firstSolanaKey,
        workerRevision: 1,
    });
    const account = harness.standardProvider.standardAccounts()[0];
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
            isConnected: true,
            publicKey: firstSolanaKey,
            workerRevision: 1,
        });
        applySolanaConfiguration(harness, {
            isConnected: true,
            publicKey: firstSolanaKey,
            workerRevision: 1,
        });
        const account = harness.standardProvider.standardAccounts()[0];
        let calls = 0;
        const switchAccount = signature => {
            calls += 1;
            applySolanaConfiguration(harness, {
                isConnected: true,
                publicKey: secondSolanaKey,
                workerRevision: 2,
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
        await assert.rejects(request, error => error.code === 4100);
        assert.equal(calls, 1);
    }
});

test("Solana retires all work when a generation transport returns false", async () => {
    const requestHarness = solanaHarness({
        isConnected: true,
        publicKey: firstSolanaKey,
        workerRevision: 1,
    });
    applySolanaConfiguration(requestHarness, {
        isConnected: true,
        publicKey: firstSolanaKey,
        workerRevision: 1,
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
});

test("Solana ignores a disconnect response after transport retirement", async () => {
    const h = connectedSolanaHarness();
    const signing = h.provider.signMessage(new Uint8Array([1]));
    const disconnect = h.provider.disconnect();
    h.setCurrent(false);
    assert.equal(h.applyDecodedEnvelope(h.provider, {id: h.disconnects[0].id, name: "revokePermissions", kind: "result", result: null}), false);
    await assert.rejects(signing, error => error.code === 4900);
    await assert.rejects(disconnect, error => error.code === 4900);
    assert.equal(h.provider.retired, true);
});

test("Solana external disconnect transport failure leaves authorization unchanged", async () => {
    const h = connectedSolanaHarness();
    h.setDisconnectPost(false);
    await assert.rejects(h.provider.externalDisconnect(), error => error.code === 4900);
    assert.equal(h.provider.publicKey.toString(), firstSolanaKey);
    assert.equal(h.provider.retired, false);
});

test("Solana accepts the maximum authoritative revision without a local counter", async () => {
    const h = connectedSolanaHarness();
    applySolanaConfiguration(h, {publicKey: firstSolanaKey, workerRevision: Number.MAX_SAFE_INTEGER});
    const pending = h.provider.signMessage(new Uint8Array([1]));
    h.applyDecodedEnvelope(h.provider, {id: h.requests[0].id, name: "signMessage", kind: "result", result: validSignature});
    assert.equal((await pending).signature.length, 64);
    assert.equal(h.Solana.snapshot(h.provider).workerRevision, Number.MAX_SAFE_INTEGER);
});

test("Solana fences stale authorization and retires pending work", async () => {
    const harness = solanaHarness({
        isConnected: true,
        publicKey: firstSolanaKey,
        workerRevision: 1,
    });
    applySolanaConfiguration(harness, {
        isConnected: true,
        publicKey: firstSolanaKey,
        workerRevision: 1,
    });
    const pending = harness.provider.signMessage(new Uint8Array([1]));
    applySolanaConfiguration(harness, {
        isConnected: true,
        publicKey: secondSolanaKey,
        workerRevision: 2,
    });
    harness.applyDecodedEnvelope(harness.provider, {
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

function notificationSlot() {
    let current = null;
    return {
        subscribeNotifications(listener) {
            current = listener;
            return () => {
                if (current === listener) { current = null; }
            };
        },
        publish(notification) { current?.(notification); },
        notificationListenerCount() { return current ? 1 : 0; },
    };
}

function ethereumFacadeTarget(name) {
    const provider = {};
    provider.address = "";
    provider.chainId = "0x1";
    provider.request = payload => Promise.resolve(`${name}:${payload.method}`);
    provider.send = provider.request;
    provider.sendAsync = (payload, callback) => callback(null, name);
    provider.enable = () => Promise.resolve([]);
    provider.isConnected = () => true;
    provider.isUnlocked = () => Promise.resolve(true);
    let retired = 0;
    let ready = false;
    const notifications = notificationSlot();
    return {
        provider,
        ...notifications,
        publishEvent(name, ...args) { notifications.publish({kind: "event", name, args}); },
        withReadyState(listener) {
            return ready && retired === 0
                ? listener(Object.freeze({chainId: provider.chainId})) === true
                : false;
        },
        publishReadiness(flushed = true) {
            ready = true;
            notifications.publish(Object.freeze({kind: "readiness", flushed}));
        },
        retire() { retired += 1; },
        retired() { return retired; },
        snapshot() {
            return {
                address: provider.address,
                chainId: provider.chainId,
            };
        },
    };
}

function solanaFacadeTarget(name, address = firstSolanaKey) {
    const notifications = notificationSlot();
    const account = {
        address,
        publicKey: new Uint8Array(32),
    };
    const calls = [];
    const provider = Object.assign({}, {
        accountState() { return account; },
        connect() { calls.push("connect"); return Promise.resolve(); },
        disconnect() { calls.push("disconnect"); return Promise.resolve(); },
        standardSignAndSendTransaction: () => Promise.resolve(name),
        standardSignMessage: () => Promise.resolve(name),
        standardSignTransaction: () => Promise.resolve(name),
    });
    let retired = 0;
    return {
        calls,
        ...notifications,
        publishEvent(name, ...args) { notifications.publish({kind: "event", name, args}); },
        publishAccountChange() { notifications.publish({kind: "accountStateChanged"}); },
        provider,
        retire() { retired += 1; },
        retired() { return retired; },
        snapshot() {
            return {
                isConnected: true,
                publicKey: address,
                workerRevision: 0,
            };
        },
    };
}

test("Wallet Standard public entry points share accounts and features", async () => {
    const harness = solanaHarness();
    applySolanaConfiguration(harness);
    const {wallet, standardProvider} = harness;
    assert.equal(standardProvider.standardFeatures(), wallet.features);
    const changes = [];
    wallet.features["standard:events"].on("change", value => changes.push(value));
    const connecting = wallet.features["standard:connect"].connect();
    grantSolana(harness, harness.requests.at(-1).id, firstSolanaKey);
    const account = (await connecting).accounts[0];
    assert.equal(wallet.accounts[0], account);
    assert.equal(standardProvider.standardAccounts()[0], account);
    assert.equal(changes.at(-1).accounts[0], account);
    assert.equal(Object.isFrozen(account), true);
    const bytes = account.publicKey;
    bytes[0] = 255;
    assert.equal(account.publicKey[0], 0);
});

test("Wallet Standard subscribers isolate errors and unsubscribe independently", () => {
    const harness = solanaHarness();
    harness.standardProvider.on("accountChanged", () => { throw new Error("ordinary listener"); });
    const unsubscribeFirst = harness.standardProvider.standardOn("change", value => {
        value.accounts = [];
        throw new Error("standard listener");
    });
    const changes = [];
    const unsubscribeSecond = harness.wallet.features["standard:events"].on(
        "change", value => changes.push(value)
    );
    vm.runInContext(`Set.prototype[Symbol.iterator] = function() {
        throw new Error("mutated iterator");
    };`, harness.context);
    applySolanaConfiguration(harness, {publicKey: firstSolanaKey, isConnected: true});
    assert.equal(changes.length, 1);
    assert.equal(changes[0].accounts[0], harness.wallet.accounts[0]);
    unsubscribeFirst();
    unsubscribeSecond();
    applySolanaConfiguration(harness, {publicKey: secondSolanaKey, isConnected: true});
    assert.equal(changes.length, 1);
});

for (const sizeGetter of ["zero", "throwing"]) {
    test(`Wallet Standard account changes ignore a ${sizeGetter} Set size getter`, () => {
        const harness = solanaHarness();
        const changes = [];
        const unsubscribe = harness.wallet.features["standard:events"].on("change", value => {
            changes.push(value.accounts.map(account => account.address));
        });
        vm.runInContext(`
            globalThis.sizeReads = 0;
            Object.defineProperty(Set.prototype, "size", {
                configurable: true,
                get() {
                    globalThis.sizeReads += 1;
                    ${sizeGetter === "zero" ? "return 0;" : "throw new Error('mutated size getter');"}
                },
            });
        `, harness.context);

        applySolanaConfiguration(harness, {publicKey: firstSolanaKey, isConnected: true});

        assert.deepEqual(normalized(changes), [[firstSolanaKey]]);
        assert.equal(vm.runInContext("sizeReads", harness.context), 0);
        unsubscribe();
        applySolanaConfiguration(harness, {publicKey: secondSolanaKey, isConnected: true});
        assert.deepEqual(normalized(changes), [[firstSolanaKey]]);
    });
}

test("public Solana events cannot synthesize Wallet Standard account changes", () => {
    const harness = connectedSolanaHarness();
    const changes = [];
    harness.wallet.features["standard:events"].on("change", value => changes.push(value));

    harness.standardProvider.emit("accountChanged", publicKey(secondSolanaKey));
    harness.standardProvider.emit("disconnect");

    assert.deepEqual(changes, []);
    assert.equal(harness.wallet.accounts[0].address, firstSolanaKey);
});

test("Solana forwarding drops events when argument iteration replaces the target", () => {
    const harness = solanaHarness();
    const replacement = connectedSolanaHarness(secondSolanaKey);
    const record = harness.exports.createStableFacadeRecord({uuid: "argument-replacement"});
    const ethereum = ethereumFacadeTarget("current");
    record.prepareTargets({ethereumProvider: ethereum, solanaProvider: harness.target}).commit();
    const events = [];
    record.solana.on("accountChanged", key => events.push(key.toString()));
    harness.context.retarget = () => record.prepareTargets({
        ethereumProvider: ethereum,
        solanaProvider: replacement.target,
    }).commit();
    vm.runInContext(`
        const originalIterator = Array.prototype[Symbol.iterator];
        let replaced = false;
        Array.prototype[Symbol.iterator] = function () {
            if (!replaced && this.length === 1 && typeof this[0]?.toBase58 === "function") {
                replaced = true;
                retarget();
            }
            return Reflect.apply(originalIterator, this, []);
        };
    `, harness.context);

    applySolanaConfiguration(harness, {publicKey: firstSolanaKey, isConnected: true});

    assert.equal(record.wallet.accounts[0].address, secondSolanaKey);
    assert.deepEqual(events, []);
});

test("Solana notification replacement survives an obsolete disposer during delivery", () => {
    const harness = solanaHarness();
    const first = [];
    const second = [];
    let disposeSecond;
    const disposeFirst = harness.exports.subscribeNotifications(harness.provider, notification => {
        first.push(notification.kind === "event" ? notification.name : notification.kind);
        disposeSecond = harness.exports.subscribeNotifications(harness.provider, next => {
            second.push(next.kind === "event" ? next.name : next.kind);
        });
    });

    applySolanaConfiguration(harness, {publicKey: firstSolanaKey, isConnected: true});
    assert.deepEqual(first, ["accountChanged"]);
    assert.deepEqual(second, ["accountStateChanged", "connect"]);
    disposeFirst();
    applySolanaConfiguration(harness, {publicKey: secondSolanaKey, isConnected: true});
    assert.deepEqual(second, ["accountStateChanged", "connect", "accountChanged", "accountStateChanged"]);
    disposeSecond();
    applySolanaConfiguration(harness, {publicKey: firstSolanaKey, isConnected: true});
    assert.equal(second.length, 4);
});

test("Wallet Standard subscriber revocation cannot deliver stale accounts to later listeners", () => {
    const harness = solanaHarness();
    const on = harness.wallet.features["standard:events"].on;
    on("change", value => {
        if (value.accounts.length > 0) { applySolanaConfiguration(harness); }
    });
    const changes = [];
    on("change", value => changes.push(value.accounts.map(account => account.address)));
    applySolanaConfiguration(harness, {publicKey: firstSolanaKey, isConnected: true});
    assert.deepEqual(normalized(harness.wallet.accounts), []);
    assert.deepEqual(normalized(changes), [[], []]);
});

test("Wallet Standard reentrant account reads cannot overwrite replacement account identity", () => {
    const harness = facadeHarness();
    const record = harness.exports.createStableFacadeRecord({
        uuid: "00000000-0000-4000-8000-000000000003",
    });
    const ethereum = ethereumFacadeTarget("ethereum");
    const first = solanaFacadeTarget("first");
    const second = solanaFacadeTarget("second", secondSolanaKey);
    record.prepareTargets({ethereumProvider: ethereum, solanaProvider: first}).commit();
    const firstRead = first.provider.accountState;
    let replacementAccount;
    first.provider.accountState = () => {
        record.prepareTargets({ethereumProvider: ethereum, solanaProvider: second}).commit();
        replacementAccount = record.wallet.accounts[0];
        return firstRead();
    };
    const account = record.wallet.accounts[0];
    assert.equal(account, replacementAccount);
    assert.equal(record.solana.standardAccounts()[0], replacementAccount);
    assert.equal(account.address, secondSolanaKey);
});

test("Wallet Standard connect cannot move to a replacement provider during options evaluation", async () => {
    const first = solanaHarness();
    const second = solanaHarness();
    applySolanaConfiguration(first);
    applySolanaConfiguration(second);
    const harness = facadeHarness();
    const record = harness.exports.createStableFacadeRecord({
        uuid: "00000000-0000-4000-8000-000000000004",
    });
    const ethereum = ethereumFacadeTarget("ethereum");
    record.prepareTargets({
        ethereumProvider: ethereum,
        solanaProvider: first.target,
    }).commit();
    const connecting = record.wallet.features["standard:connect"].connect({
        get silent() {
            record.prepareTargets({
                ethereumProvider: ethereum,
                solanaProvider: second.target,
            }).commit();
            first.Solana.retire(first.provider);
            return false;
        },
    });
    assert.equal(first.requests.length, 0);
    assert.equal(second.requests.length, 0);
    await assert.rejects(connecting, error => error.code === 4900);
});

test("Wallet Standard account reads do not invoke mutable public-key byte methods", () => {
    for (const method of ["toBytes", "toBuffer"]) {
        const harness = solanaHarness();
        applySolanaConfiguration(harness, {publicKey: firstSolanaKey, isConnected: true});
        const account = harness.wallet.accounts[0];
        const publicKey = harness.provider.publicKey;
        const original = publicKey[method].bind(publicKey);
        let calls = 0;
        publicKey[method] = () => {
            calls += 1;
            applySolanaConfiguration(harness);
            return original();
        };
        assert.equal(harness.wallet.accounts[0], account);
        assert.equal(harness.standardProvider.standardAccounts()[0], account);
        assert.equal(calls, 0);
        assert.equal(harness.provider.publicKey, publicKey);
        assert.deepEqual(Array.from(account.publicKey), new Array(32).fill(0));
    }
});

test("Solana account reads and snapshots ignore mutable public key methods and data", async () => {
    for (const behavior of ["mutate", "throw"]) {
        const harness = connectedSolanaHarness();
        const account = harness.wallet.accounts[0];
        const key = harness.provider.publicKey;
        const snapshot = normalized(harness.Solana.snapshot(harness.provider));
        const reads = overrideProviderPublicKey(key, behavior);

        assert.equal(harness.provider.publicKey, key);
        assert.equal(harness.standardProvider.publicKey, key);
        assert.equal((await harness.provider.connect()).publicKey, key);
        assert.equal(harness.wallet.accounts[0], account);
        assert.equal(harness.standardProvider.standardAccounts()[0], account);
        assert.equal(account.address, firstSolanaKey);
        assert.deepEqual(Array.from(account.publicKey), new Array(32).fill(0));
        account.publicKey.fill(9);
        assert.deepEqual(Array.from(account.publicKey), new Array(32).fill(0));
        assert.deepEqual(normalized(harness.Solana.snapshot(harness.provider)), snapshot);
        assert.equal(reads(), 0);
    }
});

test("Wallet Standard features remain cached and frozen after Object.freeze changes", () => {
    const engine = solanaHarness();
    const facade = facadeHarness();
    for (const harness of [engine, facade]) {
        vm.runInContext("Object.freeze = value => value", harness.context);
    }
    const wallet = facade.exports.createStableFacadeRecord({
        uuid: "00000000-0000-4000-8000-000000000009",
    }).wallet;
    const engineFeatures = engine.standardProvider.standardFeatures();
    assert.equal(engine.standardProvider.standardFeatures(), engineFeatures);
    for (const features of [engineFeatures, wallet.features]) {
        assert.equal(Object.isFrozen(features), true);
        assert.deepEqual(Object.keys(features).sort(), [
            "solana:signAndSendTransaction",
            "solana:signMessage",
            "solana:signTransaction",
            "standard:connect",
            "standard:disconnect",
            "standard:events",
        ]);
        for (const [name, feature] of Object.entries(features)) {
            assert.equal(Object.isFrozen(feature), true);
            assert.equal(feature.version,
                name === "solana:signMessage" ? "1.1.0" : "1.0.0");
        }
        for (const name of ["solana:signTransaction", "solana:signAndSendTransaction"]) {
            assert.deepEqual(normalized(features[name].supportedTransactionVersions),
                ["legacy", 0]);
            assert.equal(Object.isFrozen(features[name].supportedTransactionVersions), true);
        }
    }
    assert.deepEqual(normalized(wallet.chains),
        ["solana:mainnet", "solana:devnet", "solana:testnet"]);
    assert.equal(Object.isFrozen(wallet.chains), true);
});

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
    const features = wallet.features;
    const callbacks = [
        ["standard:connect", "connect"],
        ["standard:disconnect", "disconnect"],
        ["solana:signAndSendTransaction", "signAndSendTransaction"],
        ["solana:signTransaction", "signTransaction"],
        ["solana:signMessage", "signMessage"],
    ].map(([name, method]) => ({name, method, callback: features[name][method]}));
    const account = wallet.accounts[0];
    const events = [];
    const solanaEvents = [];
    const accountEvents = [];
    const on = features["standard:events"].on;
    const unsubscribe = on("change", value => accountEvents.push(value));
    assert.equal(firstSolana.notificationListenerCount(), 1);
    for (const {name, callback} of callbacks) {
        const result = await callback({});
        if (name === "standard:connect") {
            assert.equal(result.accounts[0], account);
        } else {
            assert.equal(result, name === "standard:disconnect" ? undefined : "first");
        }
    }
    assert.deepEqual(firstSolana.calls, ["connect", "disconnect"]);
    eipProvider.on("accountsChanged", value => events.push(value));
    record.solana.on("accountChanged", value => solanaEvents.push(value));
    firstEthereum.publishEvent("accountsChanged", ["first"]);
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
    assert.equal(wallet.features, features);
    assert.equal(features["standard:events"].on, on);
    assert.equal(wallet.accounts[0], account);
    assert.equal(await eipProvider.request({method: "eth_chainId"}),
        "second:eth_chainId");
    for (const {name, method, callback} of callbacks) {
        assert.equal(wallet.features[name][method], callback);
        const result = await callback({});
        if (name === "standard:connect") {
            assert.equal(result.accounts[0], account);
        } else {
            assert.equal(result, name === "standard:disconnect" ? undefined : "second");
        }
    }
    assert.deepEqual(secondSolana.calls, ["connect", "disconnect"]);
    assert.equal(firstSolana.notificationListenerCount(), 0);
    assert.equal(secondSolana.notificationListenerCount(), 1);
    secondSolana.publishAccountChange();
    assert.equal(accountEvents.at(-1).accounts[0], account);
    unsubscribe();
    assert.equal(secondSolana.notificationListenerCount(), 1);
    firstEthereum.publishEvent("accountsChanged", ["stale"]);
    secondEthereum.publishEvent("accountsChanged", ["second"]);
    firstSolana.publishEvent("accountChanged", "stale");
    secondSolana.publishEvent("accountChanged", "second");
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

    solana.publishEvent("accountChanged", "current");

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
    firstEthereum.publishReadiness();

    assert.deepEqual(connects, ["first", "second"]);
    assert.equal(
        await record.eip6963.provider.request({method: "test"}),
        "second:test"
    );
});

test("stable facade preserves queued connect replay without listeners", () => {
    const harness = facadeHarness();
    const record = harness.exports.createStableFacadeRecord({
        uuid: "00000000-0000-4000-8000-000000000009",
    });
    const ethereum = ethereumFacadeTarget("current");
    record.prepareTargets({
        ethereumProvider: ethereum,
        solanaProvider: solanaFacadeTarget("current"),
    }).commit();
    const connects = [];
    const removed = value => connects.push(["removed", normalized(value)]);
    record.ethereum.on("connect", removed);
    record.ethereum.removeListener("connect", removed);

    ethereum.provider.chainId = "0x2";
    ethereum.publishReadiness();
    harness.runTimers();
    assert.deepEqual(connects, []);
    record.ethereum.once("connect", value => {
        connects.push(["late", normalized(value)]);
    });
    assert.deepEqual(connects, []);
    harness.runTimers();
    assert.deepEqual(connects, [["late", {chainId: "0x2"}]]);
});

test("stable facade stale timers and readiness observers cannot suppress a replacement replay", () => {
    const harness = facadeHarness();
    const record = harness.exports.createStableFacadeRecord({
        uuid: "00000000-0000-4000-8000-000000000010",
    });
    const first = ethereumFacadeTarget("first");
    const second = ethereumFacadeTarget("second");
    let staleReadiness;
    const subscribeFirst = first.subscribeNotifications;
    first.subscribeNotifications = listener => {
        staleReadiness = listener;
        return subscribeFirst(listener);
    };
    record.prepareTargets({
        ethereumProvider: first,
        solanaProvider: solanaFacadeTarget("first"),
    }).commit();
    first.publishReadiness();
    const connects = [];
    record.ethereum.on("connect", value => connects.push(normalized(value)));

    second.provider.chainId = "0x2";
    second.publishReadiness();
    record.prepareTargets({
        ethereumProvider: second,
        solanaProvider: solanaFacadeTarget("second"),
    }).commit();
    assert.equal(first.notificationListenerCount(), 0);
    assert.equal(second.notificationListenerCount(), 1);
    staleReadiness({kind: "readiness", flushed: true});
    first.publishEvent("disconnect", new Error("stale disconnect"));
    assert.deepEqual(connects, []);

    assert.equal(harness.runNextTimer(), true);
    assert.deepEqual(connects, []);
    assert.equal(harness.runNextTimer(), true);
    assert.deepEqual(connects, [{chainId: "0x2"}]);
    assert.equal(harness.runNextTimer(), false);
});

test("listener inspection cannot overwrite a replacement connect replay", () => {
    const harness = inpageHarness();
    dispatchConfigurations(harness);
    harness.runTimers();
    const provider = harness.window.ethereum;
    const connects = [];
    const listener = value => connects.push(value.chainId);
    let events = Object.getOwnPropertyDescriptor(provider, "_events").value;
    let replaced = false;
    Object.defineProperty(provider, "_events", {
        configurable: true,
        get() {
            if (!replaced && events.connect === listener) {
                replaced = true;
                harness.evaluate();
                dispatchConfigurations(harness, {chainId: "0x3"});
            }
            return events;
        },
        set(value) { events = value; },
    });

    provider.on("connect", listener);
    harness.runTimers();

    assert.equal(replaced, true);
    assert.equal(provider, harness.window.ethereum);
    assert.deepEqual(connects, ["0x3"]);
});

test("stable facade preparation keeps old targets until a single commit", async () => {
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
    assert.equal(await record.eip6963.provider.request({method: "test"}),
        "current:test");
    assert.throws(() => record.prepareTargets({
        ethereumProvider: stagedEthereum,
        solanaProvider: {provider: {}},
    }));
    const hooklessEthereum = ethereumFacadeTarget("hookless");
    delete hooklessEthereum.subscribeNotifications;
    assert.throws(() => record.prepareTargets({
        ethereumProvider: hooklessEthereum,
        solanaProvider: stagedSolana,
    }), /Ethereum target is invalid/u);
    assert.equal(await record.eip6963.provider.request({method: "test"}),
        "current:test");

    assert.equal(stage.commit().ethereum, ethereum);
    assert.equal(await record.eip6963.provider.request({method: "test"}),
        "staged:test");
    assert.equal(stage.commit(), null);

    assert.equal(record.ensureWalletRegistration(), record.wallet);
    assert.equal(record.ensureWalletRegistration(), record.wallet);
    assert.equal(harness.registeredWallets.length, 1);
    assert.equal(harness.window.navigator.wallets.length, 1);
    assert.equal(harness.exports.reusableStableFacadeRecord(record), record);
    assert.equal(harness.exports.reusableStableFacadeRecord({}), null);
});

test("Wallet Standard registration retries failures and deduplicates successful hosts", () => {
    const harness = facadeHarness({registerOnDispatch: false});
    const record = harness.exports.createStableFacadeRecord({
        uuid: "00000000-0000-4000-8000-000000000010",
    });
    record.ensureWalletRegistration();
    const callback = harness.window.navigator.wallets[0];
    let attempts = 0;
    const wallets = [];
    const host = {
        register(wallet) {
            attempts += 1;
            if (attempts === 1) { throw new Error("Temporarily unavailable"); }
            wallets.push(wallet);
            return () => { throw new Error("Registration must remain active"); };
        },
    };
    callback(host);
    callback(host);
    callback(host);
    record.ensureWalletRegistration();
    assert.equal(attempts, 2);
    assert.deepEqual(wallets, [record.wallet]);
    assert.equal(harness.window.navigator.wallets.length, 1);
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

test("inpage transport survives Object.freeze replacement during initialization", async () => {
    const harness = inpageHarness({
        beforeEvaluate(_window, context) {
            vm.runInContext(`
                const originalFreeze = Object.freeze;
                window.crypto.randomUUID = () => {
                    Object.freeze = value => {
                        if (typeof value.postRPC === "function") {
                            window.capturedTransport = value;
                            return value;
                        }
                        return originalFreeze(value);
                    };
                    return "00000000-0000-4000-8000-000000000001";
                };
            `, context);
        },
    });
    vm.runInContext(`
        if (window.capturedTransport) {
            window.capturedTransport.postRPC = () => false;
        }
    `, harness.context);
    dispatchConfigurations(harness);
    const result = harness.window.ethereum.request({method: "eth_blockNumber"})
        .catch(error => error);
    const requests = pageMessages(harness, "rpc");
    assert.equal(requests.length, 1);
    const id = requests[0].message.id;
    harness.dispatch({kind: "rpc", id, response: terminalResponse({provider: "ethereum", name: null,
            id,
            result: "0x10"})});
    assert.equal(await result, "0x10");
});

function configurationSnapshot(configurations, revisions = {ethereum: 0, solana: 0}) {
    const ethereum = configurations.find(item => item.provider === "ethereum");
    const solana = configurations.find(item => item.provider === "solana");
    return {
        revisions,
        ethereum: {address: ethereum?.address ?? "", chainId: ethereum?.chainId ?? "0x1"},
        solana: solana ? {publicKey: solana.publicKey} : null,
    };
}

function dispatchConfigurations(
    harness,
    {address = "", chainId = "0x1", publicKey = null,
        ethereumRevision, solanaRevision} = {},
    generation
) {
    const current = harness.window.bigWalletInpageStableFacadeRecord.snapshots();
    harness.dispatch({
        generation, kind: "response",
        response: {kind: "configuration", state: {
            revisions: {
                ethereum: ethereumRevision ?? (current.ethereum.workerRevision ?? -1) + 1,
                solana: solanaRevision ?? (current.solana.workerRevision ?? -1) + 1,
            },
            ethereum: {address, chainId},
            solana: publicKey ? {publicKey} : null,
        }},
    });
}

function terminalResponse({id, provider, name, ...response}) {
    const kind = Object.hasOwn(response, "error") ? "error" : "result";
    delete response.chainId;
    return {kind, id, provider, name, state: null,
        ...(kind === "result" ? {approvalCommitted: false} : {}), ...response};
}

function dispatchProviderResponse(harness, {generation, ...response}) {
    harness.dispatch({generation, id: response.id, kind: "response", response: terminalResponse(response)});
}

for (const timing of ["before installation", "after configuration"]) {
    for (const replacement of ["NaN", "throwing"]) {
        test(`decoded revisions ignore ${replacement} Math.max ${timing}`, async () => {
            const poison = context => vm.runInContext(`
                globalThis.originalMax = Math.max;
                globalThis.inboundMaxCalls = 0;
                Math.max = function () {
                    globalThis.inboundMaxCalls += 1;
                    ${replacement === "NaN" ? "return NaN" : "throw new Error('replaced Math.max invoked')"};
                };
            `, context);
            const harness = inpageHarness({beforeEvaluate(_window, context) {
                if (timing === "before installation") { poison(context); }
            }});
            const firstAddress = "0x0000000000000000000000000000000000000001";
            const secondAddress = "0x0000000000000000000000000000000000000002";
            try {
                dispatchConfigurations(harness, {
                    address: firstAddress,
                    publicKey: firstSolanaKey,
                });
                if (timing === "after configuration") { poison(harness.context); }
                dispatchConfigurations(harness, {
                    address: secondAddress,
                    chainId: "0x2",
                    publicKey: secondSolanaKey,
                    solanaRevision: 4,
                });
                const snapshots = harness.window.bigWalletInpageStableFacadeAnchorV1.record.snapshots();
                assert.equal(snapshots.ethereum.address, secondAddress);
                assert.equal(snapshots.ethereum.chainId, "0x2");
                assert.equal(snapshots.ethereum.workerRevision, 1);
                assert.equal(snapshots.solana.publicKey, secondSolanaKey);
                assert.equal(snapshots.solana.workerRevision, 4);
                assert.deepEqual(normalized(await harness.window.ethereum.request({method: "eth_accounts"})), [secondAddress]);
                assert.equal(await harness.window.ethereum.request({method: "eth_chainId"}), "0x2");

                const signing = harness.window.solana.signMessage(new Uint8Array([1]));
                const request = pageMessages(harness, "request", "solana").at(-1);
                assert.equal(request.message.body.publicKey, secondSolanaKey);
                dispatchProviderResponse(harness, {
                    id: request.message.id,
                    provider: "solana",
                    name: "signMessage",
                    result: validSignature,
                });
                assert.deepEqual([...(await signing).signature], new Array(64).fill(0));
                assert.equal(vm.runInContext("inboundMaxCalls", harness.context), 0);
            } finally {
                vm.runInContext("Math.max = originalMax", harness.context);
            }
        });
    }
}

test("decoded configurations and Solana terminals do not invoke inherited serializers", async () => {
    const harness = inpageHarness();
    const chain = harness.window.ethereum.request({method: "eth_chainId"});
    const connecting = harness.window.solana.connect();
    const poison = () => vm.runInContext(`
        globalThis.inboundSerializerCalls = 0;
        Object.prototype.toJSON = function () {
            globalThis.inboundSerializerCalls += 1;
            throw new Error("inherited serializer invoked");
        };
    `, harness.context);
    const restore = () => vm.runInContext("delete Object.prototype.toJSON", harness.context);
    poison();
    try {
        dispatchConfigurations(harness, {chainId: "0x2", publicKey: firstSolanaKey});
        assert.equal(await chain, "0x2");
        assert.equal((await connecting).publicKey.toString(), firstSolanaKey);
        assert.equal(vm.runInContext("inboundSerializerCalls", harness.context), 0);
    } finally {
        restore();
    }

    const signing = harness.window.solana.signMessage(new Uint8Array([1]));
    const request = pageMessages(harness, "request", "solana").at(-1);
    poison();
    try {
        dispatchProviderResponse(harness, {
            id: request.message.id, provider: "solana", name: "signMessage",
            result: validSignature,
        });
        assert.deepEqual([...(await signing).signature], new Array(64).fill(0));
        assert.equal(vm.runInContext("inboundSerializerCalls", harness.context), 0);
    } finally {
        restore();
    }
});

test("raw ingress rejects custom serializers without executing them or revoking authorization", async () => {
    const harness = inpageHarness();
    const address = "0x0000000000000000000000000000000000000001";
    dispatchConfigurations(harness, {address, publicKey: firstSolanaKey});
    let serializerCalls = 0;
    const toJSON = () => { serializerCalls += 1; throw new Error("raw serializer invoked"); };
    const state = configurationSnapshot([], {ethereum: 0, solana: 1});
    state.ethereum = {address: "", chainId: "0x2", toJSON};
    harness.dispatch({kind: "response", response: {kind: "configuration", state}});
    assert.equal(harness.window.ethereum.selectedAddress, address);
    assert.equal(harness.window.ethereum.chainId, "0x1");

    const signing = harness.window.solana.signMessage(new Uint8Array([1]));
    const rejected = assert.rejects(signing, error => error.code === -32603);
    const firstRequest = pageMessages(harness, "request", "solana").at(-1);
    const unrelated = harness.window.solana.signMessage(new Uint8Array([2]));
    const secondRequest = pageMessages(harness, "request", "solana").at(-1);
    harness.dispatch({
        kind: "response", id: firstRequest.message.id,
        response: {
            ...terminalResponse({id: firstRequest.message.id, provider: "solana", name: "signMessage", result: validSignature}),
            toJSON,
        },
    });
    await rejected;
    assert.equal(serializerCalls, 0);
    assert.equal(harness.window.solana.publicKey.toString(), firstSolanaKey);
    dispatchProviderResponse(harness, {
        id: secondRequest.message.id, provider: "solana", name: "signMessage",
        result: validSignature,
    });
    assert.deepEqual([...(await unrelated).signature], new Array(64).fill(0));
});

test("decoded ingress gives callers independent mutable RPC results and Solana error data", async () => {
    const harness = inpageHarness();
    dispatchConfigurations(harness, {publicKey: firstSolanaKey});
    const rpc = harness.window.ethereum.request({method: "eth_getBlockByNumber", params: ["latest", false]});
    const rpcRequest = pageMessages(harness, "rpc").at(-1);
    const rawResult = JSON.parse('{"nested":{"count":1},"items":[1],"__proto__":{"remote":true},"toJSON":"remote literal"}');
    harness.dispatch({
        id: rpcRequest.message.id, kind: "rpc",
        response: terminalResponse({id: rpcRequest.message.id, provider: "ethereum", name: null, result: rawResult}),
    });
    const result = await rpc;
    assert.equal(Object.getPrototypeOf(result), vm.runInContext("Object.prototype", harness.context));
    assert.equal(Object.getPrototypeOf(result.nested), vm.runInContext("Object.prototype", harness.context));
    assert.equal(Object.hasOwn(result, "__proto__"), true);
    result.nested.count = 2;
    result.items.push(2);
    assert.equal(result.nested.count, 2);
    assert.deepEqual([...result.items], [1, 2]);
    assert.equal(rawResult.nested.count, 1);
    assert.deepEqual(rawResult.items, [1]);

    const signing = harness.window.solana.signMessage(new Uint8Array([1])).catch(error => error);
    const request = pageMessages(harness, "request", "solana").at(-1);
    const rawData = {details: {code: 1}, attempts: [1]};
    dispatchProviderResponse(harness, {
        id: request.message.id, provider: "solana", name: "signMessage",
        error: {code: -32000, message: "Signing failed", data: rawData},
    });
    const error = await signing;
    assert.equal(error.code, -32000);
    assert.equal(Object.getPrototypeOf(error.data), vm.runInContext("Object.prototype", harness.context));
    error.data.details.code = 2;
    error.data.attempts.push(2);
    assert.equal(error.data.details.code, 2);
    assert.deepEqual([...error.data.attempts], [1, 2]);
    assert.deepEqual(rawData, {details: {code: 1}, attempts: [1]});

    const withoutData = harness.window.solana.signMessage(new Uint8Array([2])).catch(error => error);
    const withoutDataRequest = pageMessages(harness, "request", "solana").at(-1);
    vm.runInContext(`Object.defineProperty(Object.prototype, "data", {
        configurable: true,
        get() { throw new Error("inherited error data invoked"); },
    })`, harness.context);
    try {
        dispatchProviderResponse(harness, {
            id: withoutDataRequest.message.id, provider: "solana", name: "signMessage",
            error: {code: 4001, message: "Canceled"},
        });
        const withoutDataError = await withoutData;
        assert.equal(withoutDataError.code, 4001);
        assert.equal(Object.hasOwn(withoutDataError, "data"), false);
    } finally {
        vm.runInContext("delete Object.prototype.data", harness.context);
    }
});

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
    assert.deepEqual(Object.keys(solanaRequest).sort(), [
        "direction", "kind", "message", "providerGeneration",
    ]);
    dispatchProviderResponse(harness, {
        id: ethereumRequest.message.id,
        name: "signTransaction",
        provider: "ethereum",
        result: "0xhash"
    });
    dispatchProviderResponse(harness, {
        id: solanaRequest.message.id,
        name: "connect",
        provider: "solana",
        result: {publicKey: firstSolanaKey},
        state: pageSnapshot({publicKey: firstSolanaKey, solana: 1}),
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
        response: terminalResponse({provider: "ethereum", name: null,
            id: rpc.message.id,
            result: "0x10"}),
    });
    assert.equal(await block, "0x10");

    const denied = window.ethereum.request({
        method: "personal_sign",
        params: ["0x01"],
    });
    const deniedRequest = pageMessages(harness, "request", "ethereum").at(-1);
    dispatchProviderResponse(harness, {
        error: {code: 4001, message: "Canceled"},
        id: deniedRequest.message.id,
        name: deniedRequest.message.name,
        provider: "ethereum"
    });
    await assert.rejects(denied, error => error.code === 4001);

    const disconnect = window.solana.disconnect();
    const disconnectRequest = pageMessages(harness, "disconnect", "solana").at(-1);
    assert.deepEqual(Object.keys(disconnectRequest).sort(), [
        "direction", "kind", "message", "providerGeneration",
    ]);
    const beforeRevision = window.bigWalletInpageStableFacadeRecord.snapshots().solana.workerRevision;
    const postedCount = harness.postedMessages.length;
    dispatchProviderResponse(harness, {
        id: disconnectRequest.message.id,
        name: "revokePermissions",
        provider: "solana",
        result: null,
        state: pageSnapshot({solana: beforeRevision + 1}),
    });
    assert.equal(await disconnect, true);
    assert.equal(window.bigWalletInpageStableFacadeRecord.snapshots().solana.workerRevision, beforeRevision + 1);
    assert.equal(harness.postedMessages.length, postedCount);
    assert.deepEqual(harness.listenerErrors, []);
});

test("inpage replaces nonconfigurable writable aliases without changing their flags", () => {
    const phantom = {};
    const aliases = ["bigwallet", "ethereum", "web3", "metamask", "solana", "phantom"];
    const harness = inpageHarness({
        beforeEvaluate(window) {
            for (const name of aliases) {
                Object.defineProperty(window, name, {
                    value: name === "phantom" ? phantom : {},
                    writable: true,
                });
            }
            Object.defineProperty(phantom, "solana", {value: {}, writable: true});
        },
    });
    const {window} = harness;
    const record = window.bigWalletInpageStableFacadeRecord;
    const expected = [record.bigwallet, record.ethereum, record.web3,
        record.ethereum, record.solana, phantom];
    for (let installation = 0; installation < 2; installation += 1) {
        for (const [index, name] of aliases.entries()) {
            assert.deepEqual(Object.getOwnPropertyDescriptor(window, name), {
                configurable: false,
                enumerable: false,
                value: expected[index],
                writable: true,
            });
        }
        assert.deepEqual(Object.getOwnPropertyDescriptor(phantom, "solana"), {
            configurable: false,
            enumerable: false,
            value: record.solana,
            writable: true,
        });
        assert.equal(harness.registeredWallets.length, 1);
        if (installation === 0) { harness.evaluate(); }
    }
});

test("locked Ethereum aliases preserve provider activation and discovery on reinjection", async () => {
    for (const accessor of [false, true]) {
        let accessorCalls = 0;
        const blockedAccess = () => { accessorCalls += 1; throw new Error("Locked"); };
        const descriptor = accessor
            ? {get: blockedAccess, set: blockedAccess}
            : {value: {}, writable: false};
        const harness = inpageHarness({
            beforeEvaluate(window) {
                Object.defineProperty(window, "ethereum", descriptor);
            },
        });
        const {window} = harness;
        const ethereum = window.bigwallet.eth;
        const solana = window.bigwallet.solana;
        const wallet = harness.registeredWallets[0];
        for (let installation = 0; installation < 2; installation += 1) {
            assert.deepEqual(Object.getOwnPropertyDescriptor(window, "ethereum"), {
                configurable: false,
                enumerable: false,
                ...descriptor,
            });
            dispatchConfigurations(harness, {publicKey: firstSolanaKey});
            assert.equal(await ethereum.request({method: "eth_chainId"}), "0x1");
            assert.equal((await solana.connect()).publicKey.toString(), firstSolanaKey);
            assert.equal(wallet.accounts[0].address, firstSolanaKey);
            window.dispatchEvent(new HarnessEvent("eip6963:requestProvider"));
            assert.equal(harness.announcements.at(-1).provider, ethereum);
            assert.equal(harness.registeredWallets.length, 1);
            assert.equal(harness.registeredWallets[0], wallet);
            assert.equal(accessorCalls, 0);
            if (installation === 0) { harness.evaluate(); }
        }
        assert.deepEqual(harness.listenerErrors, []);
    }
});

test("Phantom aliases install without inspecting proxy property descriptors", () => {
    const target = {};
    const harness = inpageHarness({
        beforeEvaluate(window) {
            window.phantom = new Proxy(target, {
                getOwnPropertyDescriptor() { throw new Error("Unsupported"); },
            });
        },
    });
    assert.equal(target.solana, harness.window.bigwallet.solana);
});

test("an unwritable Phantom namespace cannot abort provider activation", async () => {
    for (const phantom of [Object.freeze({}), new Proxy({}, {
        defineProperty() { throw new Error("Locked"); },
    })]) {
        const harness = inpageHarness({
            beforeEvaluate(window) { window.phantom = phantom; },
        });
        dispatchConfigurations(harness, {publicKey: firstSolanaKey});
        assert.equal(harness.window.phantom, phantom);
        assert.equal(await harness.window.bigwallet.eth.request({
            method: "eth_chainId",
        }), "0x1");
        assert.equal(harness.window.bigwallet.solana.publicKey.toString(), firstSolanaKey);
        assert.equal(harness.announcements.length, 1);
        assert.equal(harness.registeredWallets[0].accounts[0].address, firstSolanaKey);
    }
});

function pageSnapshot({address = "", chainId = "0x1", publicKey = null, ethereum = 0, solana = 0} = {}) {
    return {revisions: {ethereum, solana}, ethereum: {address, chainId}, solana: publicKey ? {publicKey} : null};
}

function publishSnapshot(harness, state) {
    harness.dispatch({kind: "response", response: {kind: "configuration", state}});
}

const firstEthereumAddress = "0x0000000000000000000000000000000000000001";
const secondEthereumAddress = "0x0000000000000000000000000000000000000002";

test("combined configuration commits both providers before any callback", () => {
    const h = inpageHarness();
    publishSnapshot(h, pageSnapshot());
    const observations = [];
    const observe = name => observations.push([name, h.window.ethereum.selectedAddress, h.window.solana.publicKey?.toString()]);
    h.window.ethereum.on("accountsChanged", () => observe("ethereum"));
    h.window.solana.on("accountChanged", () => observe("solana"));
    h.registeredWallets[0].features["standard:events"].on("change", () => observe("standard"));
    publishSnapshot(h, pageSnapshot({address: firstEthereumAddress, publicKey: firstSolanaKey, ethereum: 1, solana: 1}));
    assert.deepEqual(observations, ["ethereum", "solana", "standard"].map(name => [name, firstEthereumAddress, firstSolanaKey]));
});

test("provider halves independently accept newer revisions in a mixed snapshot", () => {
    const h = inpageHarness();
    publishSnapshot(h, pageSnapshot({address: firstEthereumAddress, ethereum: 4, solana: 1}));
    publishSnapshot(h, pageSnapshot({address: secondEthereumAddress, publicKey: firstSolanaKey, ethereum: 3, solana: 2}));
    assert.equal(h.window.ethereum.selectedAddress, firstEthereumAddress);
    assert.equal(h.window.solana.publicKey.toString(), firstSolanaKey);
    publishSnapshot(h, pageSnapshot({address: secondEthereumAddress, publicKey: secondSolanaKey, ethereum: 5, solana: 1}));
    assert.equal(h.window.ethereum.selectedAddress, secondEthereumAddress);
    assert.equal(h.window.solana.publicKey.toString(), firstSolanaKey);
});

test("conflicting equal revisions reject the whole snapshot atomically", () => {
    const h = inpageHarness();
    const baseline = pageSnapshot({address: firstEthereumAddress, publicKey: firstSolanaKey, ethereum: 1, solana: 1});
    publishSnapshot(h, baseline);
    const before = normalized(h.window.bigWalletInpageStableFacadeRecord.snapshots());
    for (const invalid of [
        pageSnapshot({address: secondEthereumAddress, publicKey: secondSolanaKey, ethereum: 1, solana: 2}),
        pageSnapshot({address: secondEthereumAddress, publicKey: secondSolanaKey, ethereum: 2, solana: 1}),
    ]) {
        publishSnapshot(h, invalid);
        assert.deepEqual(normalized(h.window.bigWalletInpageStableFacadeRecord.snapshots()), before);
    }
});

test("duplicate snapshots are idempotent while same-account grants fence pending signing", async () => {
    const h = inpageHarness();
    const baseline = pageSnapshot({address: firstEthereumAddress, publicKey: firstSolanaKey, ethereum: 1, solana: 1});
    publishSnapshot(h, baseline);
    let changes = 0;
    h.window.ethereum.on("accountsChanged", () => changes++);
    h.window.solana.on("accountChanged", () => changes++);
    const pending = h.window.solana.signMessage(new Uint8Array([1]));
    const request = pageMessages(h, "request", "solana").at(-1).message;
    publishSnapshot(h, baseline);
    publishSnapshot(h, {...baseline, revisions: {ethereum: 1, solana: 2}});
    dispatchProviderResponse(h, {id: request.id, provider: "solana", name: "signMessage", result: validSignature});
    await assert.rejects(pending, error => error.code === 4100);
    assert.equal(changes, 0);
});

for (const order of ["broadcast-first", "terminal-first"]) {
    test(`account grants settle exactly once with ${order} delivery`, async () => {
        const h = inpageHarness();
        publishSnapshot(h, pageSnapshot());
        const eth = h.window.ethereum.request({method: "eth_requestAccounts"});
        const sol = h.window.solana.connect();
        const ethID = pageMessages(h, "request", "ethereum").at(-1).message.id;
        const solID = pageMessages(h, "request", "solana").at(-1).message.id;
        const state = pageSnapshot({address: firstEthereumAddress, publicKey: firstSolanaKey, ethereum: 1, solana: 1});
        const events = [];
        h.window.ethereum.on("accountsChanged", () => events.push("ethereum"));
        h.window.solana.on("accountChanged", () => events.push("solana"));
        if (order === "broadcast-first") { publishSnapshot(h, state); }
        dispatchProviderResponse(h, {id: ethID, provider: "ethereum", name: "requestAccounts", state, result: [firstEthereumAddress]});
        dispatchProviderResponse(h, {id: solID, provider: "solana", name: "connect", state, result: {publicKey: firstSolanaKey}});
        if (order === "terminal-first") { publishSnapshot(h, state); }
        assert.deepEqual(normalized(await eth), [firstEthereumAddress]);
        assert.equal((await sol).publicKey.toString(), firstSolanaKey);
        assert.deepEqual(events, ["ethereum", "solana"]);
    });
}

for (const provider of ["ethereum", "solana"]) {
    for (const committed of [false, true]) {
        test(`${provider} stale connect committed=${committed} cannot undo disconnect and same-account regrant`, async () => {
            const h = inpageHarness();
            publishSnapshot(h, pageSnapshot());
            const pending = provider === "ethereum" ? h.window.ethereum.request({method: "eth_requestAccounts"}) : h.window.solana.connect();
            const message = pageMessages(h, "request", provider).at(-1).message;
            const granted = pageSnapshot({address: firstEthereumAddress, publicKey: firstSolanaKey, ethereum: 1, solana: 1});
            publishSnapshot(h, granted);
            publishSnapshot(h, pageSnapshot({ethereum: 2, solana: 2}));
            publishSnapshot(h, {...granted, revisions: {ethereum: 3, solana: 3}});
            dispatchProviderResponse(h, {
                id: message.id, provider, name: message.name, state: granted, approvalCommitted: committed,
                result: provider === "ethereum" ? [firstEthereumAddress] : {publicKey: firstSolanaKey},
            });
            if (committed) {
                const result = await pending;
                assert.deepEqual(provider === "ethereum" ? normalized(result) : result.publicKey.toString(), provider === "ethereum" ? [firstEthereumAddress] : firstSolanaKey);
            } else { await assert.rejects(pending, error => error.code === 4100); }
            assert.equal(h.window.bigWalletInpageStableFacadeRecord.snapshots()[provider].workerRevision, 3);
        });
    }
}

test("committed connect and signing settle after a newer disconnect without restoring authority", async () => {
    const h = inpageHarness();
    publishSnapshot(h, pageSnapshot());
    const connect = h.window.solana.connect();
    const connectID = pageMessages(h, "request", "solana").at(-1).message.id;
    const granted = pageSnapshot({publicKey: firstSolanaKey, solana: 1});
    publishSnapshot(h, granted);
    const signing = h.window.solana.signMessage(new Uint8Array([1]));
    const signID = pageMessages(h, "request", "solana").at(-1).message.id;
    publishSnapshot(h, pageSnapshot({solana: 2}));
    dispatchProviderResponse(h, {id: connectID, provider: "solana", name: "connect", state: granted, approvalCommitted: true, result: {publicKey: firstSolanaKey}});
    dispatchProviderResponse(h, {id: signID, provider: "solana", name: "signMessage", approvalCommitted: true, result: validSignature});
    assert.equal((await connect).publicKey.toString(), firstSolanaKey);
    assert.equal((await signing).signature.length, 64);
    assert.equal(h.window.solana.publicKey, null);
    assert.deepEqual(normalized(h.registeredWallets[0].accounts), []);
});

test("disconnect acknowledgement carries state and preserves a reentrant reconnect", async () => {
    const h = inpageHarness();
    publishSnapshot(h, pageSnapshot({publicKey: firstSolanaKey, solana: 1}));
    let reconnect;
    h.window.solana.on("disconnect", () => { reconnect = h.window.solana.connect(); });
    const disconnect = h.window.solana.externalDisconnect();
    const id = pageMessages(h, "disconnect", "solana").at(-1).message.id;
    assert.equal(h.window.solana.publicKey.toString(), firstSolanaKey);
    dispatchProviderResponse(h, {id, provider: "solana", name: "revokePermissions", state: pageSnapshot({solana: 2}), result: null});
    assert.equal(await disconnect, true);
    assert.ok(reconnect);
    const next = pageMessages(h, "request", "solana").at(-1).message;
    dispatchProviderResponse(h, {id: next.id, provider: "solana", name: "connect", state: pageSnapshot({publicKey: firstSolanaKey, solana: 3}), result: {publicKey: firstSolanaKey}});
    assert.equal((await reconnect).publicKey.toString(), firstSolanaKey);
});

test("nested other-provider updates do not suppress valid remaining notifications", () => {
    const h = inpageHarness();
    publishSnapshot(h, pageSnapshot());
    const events = [];
    h.window.ethereum.on("accountsChanged", () => {
        events.push("accounts");
        publishSnapshot(h, pageSnapshot({address: firstEthereumAddress, chainId: "0x2", publicKey: secondSolanaKey, ethereum: 1, solana: 2}));
    });
    h.window.ethereum.on("chainChanged", () => events.push("chain"));
    h.window.ethereum.on("networkChanged", () => events.push("network"));
    h.window.solana.on("accountChanged", key => events.push(key.toString()));
    publishSnapshot(h, pageSnapshot({address: firstEthereumAddress, chainId: "0x2", publicKey: firstSolanaKey, ethereum: 1, solana: 1}));
    assert.deepEqual(events, ["accounts", secondSolanaKey, "chain", "network"]);
});

test("nested same-provider snapshots suppress obsolete remaining notifications", () => {
    const h = inpageHarness();
    publishSnapshot(h, pageSnapshot());
    const events = [];
    h.window.ethereum.on("accountsChanged", () => {
        events.push("accounts");
        publishSnapshot(h, pageSnapshot({address: firstEthereumAddress, chainId: "0x3", ethereum: 2}));
    });
    h.window.ethereum.on("chainChanged", chain => events.push(chain));
    publishSnapshot(h, pageSnapshot({address: firstEthereumAddress, chainId: "0x2", ethereum: 1}));
    assert.deepEqual(events, ["accounts", "0x3"]);
});

test("Ethereum callbacks see disconnected Solana and may initiate its reconnect", async () => {
    const h = inpageHarness();
    publishSnapshot(h, pageSnapshot({address: firstEthereumAddress, publicKey: firstSolanaKey, ethereum: 1, solana: 1}));
    let connecting;
    h.window.ethereum.on("accountsChanged", () => {
        assert.equal(h.window.solana.publicKey, null);
        connecting = h.window.solana.connect();
    });
    publishSnapshot(h, pageSnapshot({ethereum: 2, solana: 2}));
    assert.ok(connecting);
    const request = pageMessages(h, "request", "solana").at(-1).message;
    dispatchProviderResponse(h, {id: request.id, provider: "solana", name: "connect", state: pageSnapshot({publicKey: firstSolanaKey, ethereum: 2, solana: 3}), result: {publicKey: firstSolanaKey}});
    assert.equal((await connecting).publicKey.toString(), firstSolanaKey);
});

test("replacement keeps public identities and establishes a fresh lower revision baseline", () => {
    const h = inpageHarness();
    publishSnapshot(h, pageSnapshot({address: firstEthereumAddress, publicKey: firstSolanaKey, ethereum: 8, solana: 9}));
    const ethereum = h.window.ethereum;
    const solana = h.window.solana;
    h.evaluate();
    publishSnapshot(h, pageSnapshot({address: secondEthereumAddress, publicKey: secondSolanaKey, ethereum: 0, solana: 0}));
    assert.equal(h.window.ethereum, ethereum);
    assert.equal(h.window.solana, solana);
    assert.equal(ethereum.selectedAddress, secondEthereumAddress);
    assert.equal(solana.publicKey.toString(), secondSolanaKey);
    assert.equal(h.window.bigWalletInpageStableFacadeRecord.snapshots().ethereum.workerRevision, 0);
});

test("committed chain terminal settles null without rolling back a newer network", async () => {
    const h = inpageHarness();
    publishSnapshot(h, pageSnapshot());
    const pending = h.window.ethereum.request({method: "wallet_switchEthereumChain", params: [{chainId: "0x2"}]});
    const request = pageMessages(h, "request", "ethereum").at(-1).message;
    publishSnapshot(h, pageSnapshot({chainId: "0x3", ethereum: 2}));
    dispatchProviderResponse(h, {id: request.id, provider: "ethereum", name: request.name, result: null, approvalCommitted: true, state: pageSnapshot({chainId: "0x2", ethereum: 1})});
    assert.equal(await pending, null);
    assert.equal(h.window.ethereum.chainId, "0x3");
});


test("bootstrap failure rejects work and recovers the same providers", async () => {
    const harness = inpageHarness();
    const ethereumProvider = harness.window.ethereum;
    const solanaProvider = harness.window.solana;
    const wallet = harness.registeredWallets[0];
    const generation = harness.window.bigWalletInpageProviderGenerationToken;
    const bootstrapFailure = error => error.code === 4900 &&
        error.message === "Failed to communicate with Big Wallet";
    const ethereumConnects = [];
    const solanaConnects = [];
    const accountChanges = [];
    let reentrantConnect;
    ethereumProvider.on("connect", value => ethereumConnects.push(value));
    solanaProvider.on("connect", value => {
        solanaConnects.push({value, connected: solanaProvider.isConnected});
        reentrantConnect = solanaProvider.connect();
    });
    wallet.features["standard:events"].on("change", value => {
        accountChanges.push(value);
    });
    const ethereum = ethereumProvider.request({method: "eth_requestAccounts"});
    const solana = solanaProvider.connect();
    let ethereumSettled = false;
    void ethereum.catch(() => { ethereumSettled = true; });

    harness.dispatch({
        generation: "stale-generation",
        kind: "configurationError",
    });
    await Promise.resolve();
    assert.equal(ethereumSettled, false);

    harness.dispatch({kind: "response", response: {kind: "configurationError", error: {code: 4900, message: "Failed to communicate with Big Wallet"}}});
    await assert.rejects(ethereum, bootstrapFailure);
    await assert.rejects(solana, bootstrapFailure);
    await assert.rejects(
        ethereumProvider.request({method: "eth_chainId"}),
        bootstrapFailure
    );
    await assert.rejects(solanaProvider.connect(), bootstrapFailure);
    const disconnect = solanaProvider.disconnect();
    assert.equal(typeof disconnect.then, "function");
    await assert.rejects(disconnect, bootstrapFailure);
    assert.equal(ethereumProvider.isConnected(), false);
    assert.equal(solanaProvider.isConnected, false);

    dispatchConfigurations(harness, {
        address: "0x1234",
        publicKey: firstSolanaKey,
    });
    assert.equal(harness.window.ethereum, ethereumProvider);
    assert.equal(harness.window.solana, solanaProvider);
    assert.equal(harness.registeredWallets[0], wallet);
    assert.equal(harness.window.bigWalletInpageProviderGenerationToken, generation);
    assert.equal(ethereumProvider.isConnected(), true);
    assert.equal(solanaProvider.isConnected, true);
    assert.equal(ethereumConnects.length, 1);
    assert.equal(solanaConnects.length, 1);
    assert.equal(solanaConnects[0].connected, true);
    assert.equal((await reentrantConnect).publicKey.toString(), firstSolanaKey);
    assert.equal(accountChanges.length, 1);
    assert.equal(wallet.accounts[0].address, firstSolanaKey);
    assert.deepEqual(normalized(await ethereumProvider.request({
        method: "eth_accounts",
    })), ["0x1234"]);
    assert.equal((await solanaProvider.connect()).publicKey.toString(), firstSolanaKey);
    assert.equal(pageMessages(harness, "request").length, 0);

    const ethereumSigning = ethereumProvider.request({
        method: "personal_sign",
        params: ["0x1234", "0x1234"],
    });
    const solanaSigning = solanaProvider.signMessage(new Uint8Array([1]));
    const ethereumRequest = pageMessages(harness, "request", "ethereum")[0].message;
    const solanaRequest = pageMessages(harness, "request", "solana")[0].message;
    assert.ok(ethereumRequest.id > 1);
    assert.ok(solanaRequest.id > 2);
    harness.dispatch({kind: "response", response: {kind: "configurationError", error: {code: 4900, message: "Failed to communicate with Big Wallet"}}});
    assert.equal(ethereumProvider.isConnected(), true);
    assert.equal(solanaProvider.isConnected, true);
    dispatchProviderResponse(harness, {
        id: ethereumRequest.id,
        provider: "ethereum",
        name: "signPersonalMessage",
        result: "0xsigned"
    });
    dispatchProviderResponse(harness, {
        id: solanaRequest.id,
        provider: "solana",
        name: "signMessage",
        result: validSignature
    });
    assert.equal(await ethereumSigning, "0xsigned");
    assert.equal((await solanaSigning).signature.length, 64);
    await assert.rejects(
        ethereum,
        error => error.code === 4900
    );
    await assert.rejects(solana, error => error.code === 4900);
});

test("bootstrap recovery reconnects copied connections without revoking accounts", async () => {
    const harness = inpageHarness();
    const ethereum = harness.window.ethereum;
    const solana = harness.window.solana;
    const wallet = harness.registeredWallets[0];
    const ethereumEvents = [];
    const solanaEvents = [];
    const accountChanges = [];
    for (const event of ["connect", "disconnect"]) {
        ethereum.on(event, () => {
            ethereumEvents.push([event, ethereum.isConnected()]);
        });
        solana.on(event, () => {
            solanaEvents.push([event, solana.isConnected]);
        });
    }
    const configuration = {
        address: "0x1234",
        publicKey: firstSolanaKey,
        solanaRevision: 5,
    };
    dispatchConfigurations(harness, configuration);
    harness.runTimers();
    const account = wallet.accounts[0];
    const snapshots = () => harness.window.bigWalletInpageStableFacadeRecord.snapshots();
    ethereum.on("accountsChanged", value => accountChanges.push(value));
    solana.on("accountChanged", value => accountChanges.push(value));
    wallet.features["standard:events"].on("change", value => accountChanges.push(value));

    harness.evaluate();
    const generation = harness.window.bigWalletInpageProviderGenerationToken;
    harness.dispatch({kind: "response", response: {kind: "configurationError", error: {code: 4900, message: "Failed to communicate with Big Wallet"}}});
    harness.runTimers();
    const failed = snapshots();
    assert.equal(failed.ethereum.isConnected, false);
    assert.equal(failed.solana.isConnected, false);
    assert.deepEqual(ethereumEvents, [["connect", true], ["disconnect", false]]);
    assert.deepEqual(solanaEvents, [["connect", true], ["disconnect", false]]);
    assert.equal(ethereum.selectedAddress, configuration.address);
    assert.equal(solana.publicKey.toString(), firstSolanaKey);
    assert.equal(wallet.accounts[0], account);
    for (const provider of ["ethereum", "solana"]) {
        assert.equal(failed[provider].workerRevision, null);
    }
    harness.dispatch({kind: "response", response: {kind: "configurationError", error: {code: 4900, message: "Failed to communicate with Big Wallet"}}});
    dispatchConfigurations(harness, configuration);
    harness.runTimers();
    assert.equal(harness.window.ethereum, ethereum);
    assert.equal(harness.window.solana, solana);
    assert.equal(harness.registeredWallets[0], wallet);
    assert.equal(harness.window.bigWalletInpageProviderGenerationToken, generation);
    assert.deepEqual(ethereumEvents, [
        ["connect", true], ["disconnect", false], ["connect", true],
    ]);
    assert.deepEqual(solanaEvents, ethereumEvents);
    assert.equal(snapshots().solana.isConnected, true);
    assert.equal(wallet.accounts[0], account);
    assert.deepEqual(accountChanges, []);
    assert.deepEqual(normalized(await ethereum.request({method: "eth_accounts"})), ["0x1234"]);
    assert.equal((await solana.connect()).publicKey.toString(), firstSolanaKey);

    harness.dispatch({kind: "response", response: {kind: "configurationError", error: {code: 4900, message: "Failed to communicate with Big Wallet"}}});
    dispatchConfigurations(harness, configuration);
    harness.runTimers();
    assert.equal(ethereumEvents.length, 3);
    assert.equal(solanaEvents.length, 3);
    assert.deepEqual(accountChanges, []);
});

test("bootstrap errors ignore a throwing inherited Error serializer", async () => {
    const harness = inpageHarness({
        beforeEvaluate(_window, context) {
            vm.runInContext(`Error.prototype.toJSON = function () {
                throw new Error("inherited Error serializer invoked");
            };`, context);
        },
    });
    const ethereum = harness.window.ethereum.request({method: "eth_chainId"});
    const solana = harness.window.solana.connect();
    harness.dispatch({kind: "response", response: {kind: "configurationError", error: {code: 4900, message: "Failed to communicate with Big Wallet"}}});
    const isBootstrapFailure = error => error.code === 4900 &&
        error.message === "Failed to communicate with Big Wallet";
    await assert.rejects(ethereum, isBootstrapFailure);
    await assert.rejects(solana, isBootstrapFailure);
    dispatchConfigurations(harness, {publicKey: firstSolanaKey});
    assert.equal(await harness.window.ethereum.request({method: "eth_chainId"}), "0x1");
    assert.equal((await harness.window.solana.connect()).publicKey.toString(), firstSolanaKey);
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
        response: {kind: "configuration", state: new Array(65).fill({chainId: "0x2"})},
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
        ...terminal
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
        response: terminalResponse({id: malformedMessage.message.id,
            state: {ethereum: null, solana: null},
            name: malformedMessage.message.name,
            provider: "ethereum",
            result: "0xhash"}),
    });
    await assert.rejects(
        malformedConfiguration,
        error => error.code === -32603
    );
});

test("inpage configuration descriptor reentry preserves the newer configuration", () => {
    for (const surface of ["state", "address"]) {
        const harness = inpageHarness();
        const newerAddress = "0x0000000000000000000000000000000000000003";
        const staleAddress = "0x0000000000000000000000000000000000000002";
        let reentered = false;
        const trap = (target, name) => {
            if (name === surface && !reentered) {
                reentered = true;
                dispatchConfigurations(harness, {address: newerAddress, chainId: "0x3"});
            }
            return Reflect.getOwnPropertyDescriptor(target, name);
        };
        const ethereum = {address: staleAddress, chainId: "0x2"};
        let response = {kind: "configuration", state: {
            ethereum: surface === "address" ? new Proxy(ethereum, {getOwnPropertyDescriptor: trap}) : ethereum,
            solana: null, revisions: {ethereum: 0, solana: 0},
        }};
        if (surface === "state") { response = new Proxy(response, {getOwnPropertyDescriptor: trap}); }
        harness.dispatch({kind: "response", response});
        assert.equal(reentered, true);
        assert.equal(harness.window.ethereum.selectedAddress, newerAddress);
        assert.equal(harness.window.ethereum.chainId, "0x3");
    }
});

test("Solana configuration ignores public key overrides and preserves wrapper replacement", async () => {
    for (const behavior of ["mutate", "throw"]) {
        const harness = inpageHarness();
        dispatchConfigurations(harness, {publicKey: firstSolanaKey});
        const provider = harness.window.solana;
        const wallet = harness.registeredWallets[0];
        const account = wallet.accounts[0];
        const firstKey = provider.publicKey;
        const events = [];
        provider.on("accountChanged", key => events.push(key));
        const reads = overrideProviderPublicKey(firstKey, behavior);

        dispatchConfigurations(harness, {
            publicKey: firstSolanaKey,
            solanaRevision: 2,
        });
        const refreshedKey = provider.publicKey;
        assert.notEqual(refreshedKey, firstKey);
        assert.equal(refreshedKey.toString(), firstSolanaKey);
        assert.equal((await provider.connect()).publicKey, refreshedKey);
        assert.equal(wallet.accounts[0], account);
        assert.deepEqual(events, []);
        assert.equal(reads(), 0);

        dispatchConfigurations(harness, {
            publicKey: secondSolanaKey,
            solanaRevision: 3,
        });
        assert.notEqual(provider.publicKey, refreshedKey);
        assert.equal(provider.publicKey.toString(), secondSolanaKey);
        assert.equal(events.length, 1);
        assert.equal(events[0], provider.publicKey);
        assert.notEqual(wallet.accounts[0], account);
        assert.equal(wallet.accounts[0].address, secondSolanaKey);
    }
});

test("Solana clearing authorization does not read the public key wrapper", async () => {
    for (const behavior of ["mutate", "throw"]) {
        for (const trigger of ["configuration", "external", "response", "retirement"]) {
            const harness = connectedSolanaHarness();
            const reads = overrideProviderPublicKey(harness.provider.publicKey, behavior);
            const events = [];
            harness.standardProvider.on("accountChanged", key => events.push(["accountChanged", key]));
            harness.standardProvider.on("disconnect", () => events.push(["disconnect"]));
            if (trigger === "configuration") {
                applySolanaConfiguration(harness, {workerRevision: 2});
            } else if (trigger === "external") {
                applySolanaConfiguration(harness);
            } else if (trigger === "retirement") {
                harness.Solana.retire(harness.provider);
            } else {
                const disconnecting = harness.provider.disconnect();
                applySolanaConfiguration(harness);
                harness.applyDecodedEnvelope(harness.provider, {
                    id: harness.disconnects[0].id,
                    kind: "result",
                    name: "disconnect",
                    result: true,
                });
                await disconnecting;
            }
            assert.equal(reads(), 0);
            assert.equal(harness.provider.publicKey, null);
            assert.equal(harness.provider.isConnected, false);

            assert.equal(harness.Solana.snapshot(harness.provider).publicKey, null);
            assert.deepEqual(normalized(harness.wallet.accounts), []);
            assert.deepEqual(events, [["accountChanged", null], ["disconnect"]]);
        }
    }
});

test("Solana accepted connections preserve public wrapper identity", async () => {
    const harness = solanaHarness();
    applySolanaConfiguration(harness);
    const events = [];
    harness.standardProvider.on("connect", key => events.push(["connect", key]));
    harness.standardProvider.on("accountChanged", key => events.push(["accountChanged", key]));
    const connecting = harness.provider.connect();
    grantSolana(harness, harness.requests.at(-1).id, firstSolanaKey);
    const {publicKey: key} = await connecting;
    assert.equal(harness.provider.publicKey, key);
    assert.equal(harness.standardProvider.publicKey, key);
    assert.equal((await harness.provider.connect()).publicKey, key);
    assert.deepEqual(events, [["accountChanged", key], ["connect", key]]);
    assert.equal(key.toString(), firstSolanaKey);
    assert.equal(key.toBase58(), firstSolanaKey);
    assert.equal(key.toJSON(), firstSolanaKey);
    assert.equal(key.equals(publicKey()), true);
    assert.deepEqual(Array.from(key.toBytes()), new Array(32).fill(0));
    assert.deepEqual(Array.from(key.toBuffer()), new Array(32).fill(0));
    assert.equal(Object.isFrozen(key), false);
    key.stringValue = secondSolanaKey;
    assert.equal(key.toString(), secondSolanaKey);
    assert.equal(harness.Solana.snapshot(harness.provider).publicKey, firstSolanaKey);
});

test("Solana facade snapshots and reinjection retain canonical identity after wrapper mutation", () => {
    for (const behavior of ["mutate", "throw"]) {
        const harness = inpageHarness();
        dispatchConfigurations(harness, {
            publicKey: firstSolanaKey,
        });
        const record = harness.window.bigWalletInpageStableFacadeRecord;
        const before = normalized(record.snapshots().solana);
        const provider = harness.window.solana;
        const account = record.wallet.accounts[0];
        const key = provider.publicKey;
        const reads = overrideProviderPublicKey(key, behavior);
        assert.deepEqual(normalized(record.snapshots().solana), before);

        harness.evaluate();

        assert.equal(harness.window.solana, provider);
        assert.equal(harness.window.bigWalletInpageStableFacadeRecord, record);
        assert.notEqual(provider.publicKey, key);
        assert.equal(provider.publicKey.toString(), firstSolanaKey);
        assert.equal(record.wallet.accounts[0], account);
        assert.deepEqual(normalized(record.snapshots().solana), {...before, workerRevision: null});
        assert.equal(reads(), 0);
    }
});

test("invalid nested ingress cannot suppress a valid outer configuration", () => {
    const harness = inpageHarness();
    let didReenter = false;
    const response = new Proxy({
        kind: "configuration", state: {
            ethereum: {address: "", chainId: "0x2"},
            solana: null, revisions: {ethereum: 0, solana: 0},
        },
    }, {
        getOwnPropertyDescriptor(target, name) {
            if (name === "state" && !didReenter) {
                didReenter = true;
                harness.dispatch({
                    generation: "stale-generation",
                    kind: "response",
                    response: {kind: "configuration", state: configurationSnapshot([], undefined)},
                });
                harness.dispatch({kind: "invalid", response: terminalResponse({id: undefined})});
                harness.dispatch({
                    kind: "response",
                    response: {kind: "configuration", state: configurationSnapshot([{
                            chainId: 2,
                            provider: "ethereum",
                            address: "",
                        }], undefined)},
                });
                const throwingResponse = new Proxy({
                    kind: "configuration", state: {ethereum: null, solana: null, revisions: {ethereum: 0, solana: 0}},
                }, {
                    getOwnPropertyDescriptor(nestedTarget, nestedName) {
                        if (nestedName === "state") {
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
    const response = new Proxy(terminalResponse({
        id: message.message.id, name: message.message.name,
        provider: "ethereum", result: null,
    }), {
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
    const terminal = terminalResponse({
        id: message.message.id, name: message.message.name,
        provider: "ethereum", result: null,
    });
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
        response: terminalResponse({id: directMessage.message.id + 1,
            name: directMessage.message.name,
            provider: "ethereum",
            result: "wrong"}),
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
        response: terminalResponse({provider: "ethereum", name: null,
            id: rpcMessage.message.id + 1,
            result: "wrong"}),
    });
    await assert.rejects(rpc, error => error.code === -32603);
});

test("the RPC route cannot deliver provider configuration or configuration failures", async () => {
    const address = "0x0000000000000000000000000000000000000001";
    const injectedAddress = "0x0000000000000000000000000000000000000002";
    for (const kind of ["result", "error", "configuration", "configurationError"]) {
        const harness = inpageHarness();
        dispatchConfigurations(harness, {address, publicKey: firstSolanaKey});
        const changes = [];
        harness.window.ethereum.on("accountsChanged", value => changes.push(value));
        harness.window.ethereum.on("chainChanged", value => changes.push(value));
        harness.window.solana.on("accountChanged", value => changes.push(value));
        const outcome = harness.window.ethereum.request({method: "eth_blockNumber"})
            .then(result => ({result}), error => ({error}));
        const id = pageMessages(harness, "rpc").at(-1).message.id;
        const state = {
            revisions: {ethereum: 99, solana: 99},
            ethereum: {address: injectedAddress, chainId: "0x2"},
            solana: {publicKey: secondSolanaKey},
        };
        const error = {code: 4900, message: "Injected configuration failure"};
        const response = kind === "configuration" ? {kind, state}
            : kind === "configurationError" ? {kind, error}
                : terminalResponse({id, provider: "ethereum", name: null, state,
                    ...(kind === "result" ? {result: "0x10"} : {error})});

        harness.dispatch({kind: "rpc", id, response});

        assert.equal(harness.window.ethereum.selectedAddress, address);
        assert.equal(harness.window.ethereum.chainId, "0x1");
        assert.equal(harness.window.solana.publicKey.toString(), firstSolanaKey);
        assert.deepEqual(changes, []);
        assert.equal((await outcome).error.code, -32603);
    }
});

test("RPC errors cannot revoke the page wallet through authorization metadata", async () => {
    const harness = inpageHarness();
    const address = "0x0000000000000000000000000000000000000001";
    dispatchConfigurations(harness, {address, publicKey: firstSolanaKey});
    const pending = harness.window.ethereum.request({method: "eth_blockNumber"});
    const id = pageMessages(harness, "rpc").at(-1).message.id;
    harness.dispatch({kind: "rpc", id, response: terminalResponse({
        id, provider: "ethereum", name: null, authorizationFailure: true,
        error: {code: 4100, message: "RPC denied", data: {reason: "endpoint"}},
    })});
    await assert.rejects(pending, error => error.code === -32603);
    assert.equal(harness.window.ethereum.selectedAddress, address);
    assert.equal(harness.window.solana.publicKey.toString(), firstSolanaKey);
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
        result: validSignature
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
        result: validSignature
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
        response: terminalResponse({provider: "ethereum", name: null,
            id: wrongKindMessage.message.id,
            result: "wrong"}),
    });
    await assert.rejects(wrongKind, error => error.code === -32603);
});

test("Solana unauthorized response changes accounts only through its authoritative snapshot", async () => {
    const h = inpageHarness();
    publishSnapshot(h, pageSnapshot({publicKey: firstSolanaKey, solana: 1}));
    const pending = h.window.solana.signMessage(new Uint8Array([1]));
    const id = pageMessages(h, "request", "solana").at(-1).message.id;
    dispatchProviderResponse(h, {id, provider: "solana", name: "signMessage", error: {code: 4100, message: "Unauthorized"}, state: pageSnapshot({solana: 2})});
    await assert.rejects(pending, error => error.code === 4100);
    assert.equal(h.window.solana.publicKey, null);
    assert.equal(h.window.bigWalletInpageStableFacadeRecord.snapshots().solana.workerRevision, 2);
});

test("Solana 4100 without an account marker leaves authorization intact", async () => {
    const harness = inpageHarness();
    dispatchConfigurations(harness, {publicKey: firstSolanaKey});
    const request = harness.window.solana.signMessage(new Uint8Array([1]));
    const message = pageMessages(harness, "request", "solana").at(-1);
    dispatchProviderResponse(harness, {
        error: {code: 4100, message: "Authorization changed while the request was pending"},
        id: message.message.id,
        name: message.message.name,
        provider: "solana"
    });

    await assert.rejects(request, error => error.code === 4100);
    assert.equal(harness.window.solana.publicKey.toString(), firstSolanaKey);
    assert.equal(harness.window.solana.publicKey.toString(), firstSolanaKey);
});

test("a newer null Solana snapshot disconnects without an outbound request", () => {
    const h = inpageHarness();
    publishSnapshot(h, pageSnapshot({publicKey: firstSolanaKey, solana: 1}));
    const count = h.postedMessages.length;
    publishSnapshot(h, pageSnapshot({solana: 2}));
    assert.equal(h.window.solana.publicKey, null);
    assert.equal(h.window.solana.isConnected, false);
    assert.equal(h.postedMessages.length, count);
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
        response: {kind: "configuration", state: configurationSnapshot([{
                chainId: "0x1",
                provider: "ethereum",
                address: "",
            }], undefined)},
    });
    await rejected;
    assert.equal(harness.window.solana.didGetLatestConfiguration, true);
    assert.equal(harness.window.solana.publicKey, null);
});

test("same-key Solana regrant survives a late unauthorized response snapshot", async () => {
    const h = inpageHarness();
    publishSnapshot(h, pageSnapshot({publicKey: firstSolanaKey, solana: 1}));
    const pending = h.window.solana.signMessage(new Uint8Array([1]));
    const id = pageMessages(h, "request", "solana").at(-1).message.id;
    publishSnapshot(h, pageSnapshot({solana: 2}));
    publishSnapshot(h, pageSnapshot({publicKey: firstSolanaKey, solana: 3}));
    dispatchProviderResponse(h, {id, provider: "solana", name: "signMessage", error: {code: 4100, message: "Old authorization"}, state: pageSnapshot({solana: 2})});
    await assert.rejects(pending, error => error.code === 4100);
    assert.equal(h.window.solana.publicKey.toString(), firstSolanaKey);
});

test("missing, extra, and malformed configuration entries are ignored atomically", async () => {
    const harness = inpageHarness();
    dispatchConfigurations(harness, {publicKey: firstSolanaKey});
    const before = normalized(harness.window.bigWalletInpageStableFacadeRecord.snapshots());
    const state = {
        ethereum: {address: "", chainId: "0x2"},
        solana: {publicKey: secondSolanaKey},
        revisions: {ethereum: 1, solana: 2},
    };
    const missing = {...state};
    delete missing.solana;
    const invalidStates = [
        missing, {...state, extraProvider: null}, [state.ethereum, state.solana],
        {...state, ethereum: {...state.ethereum, address: []}},
        {...state, solana: {...state.solana, publicKey: "invalid-public-key"}},
        ...[2, "0X1", "0xA", "0x01"].map(chainId => ({...state, ethereum: {...state.ethereum, chainId}})),
    ];
    for (const state of invalidStates) {
        harness.dispatch({kind: "response", response: {kind: "configuration", state}});
    }
    assert.equal(harness.window.solana.publicKey.toString(), firstSolanaKey);
    assert.deepEqual(normalized(harness.window.bigWalletInpageStableFacadeRecord.snapshots()), before);
    assert.equal(await harness.window.ethereum.request({method: "eth_chainId"}), "0x1");
});

test("Solana ingress preserves canonical error data and signature metadata", async () => {
    const harness = inpageHarness();
    dispatchConfigurations(harness, {publicKey: firstSolanaKey});
    for (const data of [{reason: "denied"}, {signature: validSignature}]) {
        const request = harness.window.solana.signMessage(new Uint8Array([1]));
        const message = pageMessages(harness, "request", "solana").at(-1);
        dispatchProviderResponse(harness, {
            error: {code: 4001, message: "Denied", data}, id: message.message.id,
            name: message.message.name, provider: "solana",
        });
        await assert.rejects(request, error => {
            assert.equal(error.code, 4001);
            assert.deepEqual(normalized(error.data), data);
            return true;
        });
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
        solanaRevision: 1,
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
        response: terminalResponse({provider: "ethereum", name: null,
            id: oldRPCMessage.message.id,
            result: "stale"}),
    });
    dispatchProviderResponse(harness, {
        generation: secondGeneration,
        id: oldSignMessage.message.id,
        name: oldSignMessage.message.name,
        provider: "solana",
        result: validSignature
    });
    await Promise.resolve();
    assert.equal(currentSettled, false);
    harness.dispatch({
        id: currentMessage.message.id,
        kind: "rpc",
        response: terminalResponse({provider: "ethereum", name: null,
            id: currentMessage.message.id,
            result: "current"}),
    });
    assert.equal(await current, "current");
    assert.notEqual(firstGeneration, secondGeneration);
});

test("Ethereum readiness preserves a replacement observer and reads state without scheduling", () => {
    const module = moduleHarness(ethereumSource);
    const Ethereum = module.exports.default;
    const engine = new Ethereum("readiness-generation", {
        isCurrent: () => true,
        postDisconnect: () => true,
        postRequest: () => true,
        postRPC: () => true,
    });
    const deliveries = [];
    const readReadyState = label => {
        return module.exports.withReadyState(engine, payload => {
            assert.equal(Object.isFrozen(payload), true);
            deliveries.push([label, payload.chainId]);
            return true;
        });
    };
    assert.equal(readReadyState("loading"), false);
    let disposeSecond;
    const disposeFirst = module.exports.subscribeNotifications(engine, notification => {
        if (notification.kind !== "readiness") { return; }
        assert.equal(Object.isFrozen(notification), true);
        assert.equal(notification.flushed, true);
        assert.equal(readReadyState("first"), true);
        disposeSecond = module.exports.subscribeNotifications(engine, next => {
            if (next.kind !== "readiness") { return; }
            assert.equal(next.flushed, true);
            assert.equal(readReadyState("second"), true);
        });
    });
    module.exports.applyDecodedEnvelope(engine, {
        kind: "configuration",
        workerRevision: 2,
        configuration: {address: "", chainId: "0x2"},
    });
    assert.deepEqual(deliveries, [["first", "0x2"]]);
    disposeFirst();
    module.runTimers();
    assert.deepEqual(deliveries, [["first", "0x2"]]);
    module.exports.applyDecodedEnvelope(engine, {
        kind: "configuration",
        workerRevision: 3,
        configuration: {address: "", chainId: "0x3"},
    });
    module.runTimers();
    assert.deepEqual(deliveries, [["first", "0x2"], ["second", "0x3"]]);
    disposeSecond();
    module.exports.applyDecodedEnvelope(engine, {
        kind: "configuration",
        workerRevision: 4,
        configuration: {address: "", chainId: "0x4"},
    });
    module.runTimers();
    assert.equal(deliveries.length, 2);
});

for (const consumedConnect of [false, true]) {
    test(`current facade adopts a replacement engine with connect consumed=${consumedConnect}`, async () => {
        let record;
        let account;
        const connects = [];
        const chains = [];
        const oldEthereum = ethereumFacadeTarget("old");
        const oldSolana = solanaFacadeTarget("old");
        const harness = inpageHarness({
            beforeEvaluate(window, context) {
                const originalFacade = new vm.Script(`(() => {
                    "use strict";
                    const module = {exports: {}};
                    ${stableFacadesSource}
                    return module.exports;
                })()`).runInContext(context);
                record = originalFacade.createStableFacadeRecord({
                    uuid: "00000000-0000-4000-8000-000000000088",
                });
                record.prepareTargets({
                    ethereumProvider: oldEthereum,
                    solanaProvider: oldSolana,
                }).commit();
                account = record.wallet.accounts[0];
                if (!consumedConnect) { oldEthereum.publishReadiness(); }
                record.ethereum.on("connect", payload => connects.push(payload.chainId));
                if (consumedConnect) { oldEthereum.publishReadiness(); }
                record.ethereum.on("chainChanged", chainId => chains.push(chainId));
                record.ensureWalletRegistration();
                record.announceEthereum();
                Object.defineProperty(window, "bigWalletInpageStableFacadeAnchorV1", {
                    value: Object.freeze({
                        initialSnapshots: record.snapshots(),
                        record,
                        version: 2,
                    }),
                });
            },
        });
        const provider = record.ethereum;
        const wallet = record.wallet;
        const uuid = record.eip6963.uuid;
        assert.equal(harness.window.ethereum, provider);
        assert.equal(harness.window.bigWalletInpageStableFacadeRecord, record);
        assert.equal(wallet.accounts[0], account);
        assert.equal(oldEthereum.retired(), 1);
        assert.equal(oldSolana.retired(), 1);

        dispatchConfigurations(harness, {chainId: "0x2", publicKey: firstSolanaKey});
        assert.deepEqual(connects, consumedConnect ? ["0x1"] : []);
        harness.runTimers();
        assert.deepEqual(connects, [consumedConnect ? "0x1" : "0x2"]);
        assert.deepEqual(chains, ["0x2"]);
        oldEthereum.publishEvent("chainChanged", "stale");
        assert.deepEqual(chains, ["0x2"]);
        assert.equal(await provider.request({method: "eth_chainId"}), "0x2");

        const pending = provider.request({method: "eth_blockNumber"});
        const rejected = assert.rejects(pending, error => error.code === 4900);
        harness.evaluate();
        await rejected;
        dispatchConfigurations(harness, {chainId: "0x3", publicKey: firstSolanaKey});
        harness.runTimers();
        assert.deepEqual(chains, ["0x2", "0x3"]);
        assert.deepEqual(connects, [consumedConnect ? "0x1" : "0x2"]);
        assert.equal(harness.window.ethereum, provider);
        assert.equal(harness.window.bigWalletInpageStableFacadeRecord, record);
        assert.equal(record.eip6963.uuid, uuid);
        assert.equal(record.wallet, wallet);
        assert.equal(wallet.accounts[0], account);
        assert.deepEqual(harness.registeredWallets, [wallet]);
        assert.equal(harness.listenerCount("wallet-standard:app-ready"), 1);
        assert.equal(harness.listenerCount("message"), 1);
        assert.equal(harness.listenerCount("eip6963:requestProvider"), 1);
        assert.equal(await provider.request({method: "eth_chainId"}), "0x3");
    });
}

for (const changeAfterFirst of [false, true]) {
    test(`queued Wallet Standard batches bind initial revision and fence subsequent items changed=${changeAfterFirst}`, async () => {
        const h = solanaHarness({publicKey: firstSolanaKey, isConnected: true});
        const account = h.wallet.accounts[0];
        const input = {account, message: new Uint8Array([1])};
        const pending = h.provider.standardSignMessage(input, input);
        const result = pending.then(value => ({value}), error => ({error}));
        assert.equal(h.requests.length, 0);
        applySolanaConfiguration(h, {publicKey: firstSolanaKey, workerRevision: 3});
        for (let i = 0; i < 5; i++) { await Promise.resolve(); }
        assert.equal(h.requests.length, 1);
        if (changeAfterFirst) {
            applySolanaConfiguration(h, {publicKey: firstSolanaKey, workerRevision: 4});
        }
        h.applyDecodedEnvelope(h.provider, {id: h.requests[0].id, name: "signMessage", kind: "result", result: validSignature, approvalCommitted: true});
        for (let i = 0; i < 5; i++) { await Promise.resolve(); }
        if (changeAfterFirst) {
            assert.equal((await result).error.code, 4100);
            assert.equal(h.requests.length, 1);
        } else {
            assert.equal(h.requests.length, 2);
            h.applyDecodedEnvelope(h.provider, {id: h.requests[1].id, name: "signMessage", kind: "result", result: validSignature});
            assert.equal((await result).value.length, 2);
        }
    });
}

test("bootstrap callbacks enqueue behind earlier pending requests", async () => {
    const h = ethereumHarness({address: "", chainId: "0x1"});
    const order = [];
    h.setRPCObserver(message => order.push(JSON.parse(message.body).method));
    const first = h.provider.request({method: "eth_blockNumber"});
    let second;
    h.provider.on("chainChanged", () => { second = h.provider.request({method: "eth_gasPrice"}); });
    applyEthereumConfiguration(h, "", "0x2");
    assert.deepEqual(order, ["eth_blockNumber", "eth_gasPrice"]);
    for (const request of h.rpc) { h.applyDecodedEnvelope({id: request.message.id, kind: "result", result: "0x1"}); }
    await Promise.all([first, second]);
});

test("configuration preparation cannot overwrite a reentrant newer snapshot", () => {
    const h = inpageHarness();
    publishSnapshot(h, pageSnapshot());
    h.context.publishNewer = () => publishSnapshot(h, pageSnapshot({chainId: "0x3", publicKey: secondSolanaKey, ethereum: 2, solana: 2}));
    vm.runInContext(`
        const OriginalUint8Array = Uint8Array;
        let triggered = false;
        globalThis.Uint8Array = new Proxy(OriginalUint8Array, {
            construct(target, args) {
                if (!triggered) { triggered = true; publishNewer(); }
                return Reflect.construct(target, args);
            },
        });
    `, h.context);
    publishSnapshot(h, pageSnapshot({chainId: "0x2", publicKey: firstSolanaKey, ethereum: 1, solana: 1}));
    assert.equal(h.window.ethereum.chainId, "0x3");
    assert.equal(h.window.solana.publicKey.toString(), secondSolanaKey);
});

test("reentrant Ethereum preparation preserves an independent Solana connect", async () => {
    const h = inpageHarness();
    publishSnapshot(h, pageSnapshot());
    const connecting = h.window.solana.connect();
    const request = pageMessages(h, "request", "solana").at(-1).message;
    h.context.publishNewerEthereum = () => publishSnapshot(h,
        pageSnapshot({chainId: "0x3", ethereum: 2}));
    vm.runInContext(`
        const OriginalUint8Array = Uint8Array;
        let triggered = false;
        globalThis.Uint8Array = new Proxy(OriginalUint8Array, {
            construct(target, args) {
                if (!triggered) { triggered = true; publishNewerEthereum(); }
                return Reflect.construct(target, args);
            },
        });
    `, h.context);
    dispatchProviderResponse(h, {
        id: request.id, provider: "solana", name: "connect",
        result: {publicKey: firstSolanaKey}, approvalCommitted: true,
        state: pageSnapshot({chainId: "0x2", publicKey: firstSolanaKey, ethereum: 1, solana: 1}),
    });
    assert.equal((await connecting).publicKey.toString(), firstSolanaKey);
    assert.equal(h.window.ethereum.chainId, "0x3");
    assert.equal(h.window.solana.publicKey?.toString(), firstSolanaKey);
    assert.equal(h.window.solana.isConnected, true);
    const snapshots = h.window.bigWalletInpageStableFacadeRecord.snapshots();
    assert.equal(snapshots.ethereum.workerRevision, 2);
    assert.equal(snapshots.solana.workerRevision, 1);
});

test("configuration preparation errors settle correlated requests without partial updates", async () => {
    const h = inpageHarness();
    publishSnapshot(h, pageSnapshot());
    let outcome;
    const switching = h.window.ethereum.request({method: "wallet_switchEthereumChain", params: [{chainId: "0x2"}]});
    switching.then(value => { outcome = {value}; }, error => { outcome = {error}; });
    const request = pageMessages(h, "request", "ethereum").at(-1).message;
    vm.runInContext(`
        const OriginalUint8Array = Uint8Array;
        let constructions = 0;
        globalThis.Uint8Array = new Proxy(OriginalUint8Array, {
            construct(target, args) {
                if (++constructions === 3) { throw new Error("Public key construction failed"); }
                return Reflect.construct(target, args);
            },
        });
    `, h.context);
    const state = pageSnapshot({chainId: "0x2", publicKey: firstSolanaKey, ethereum: 1, solana: 1});
    dispatchProviderResponse(h, {
        id: request.id, provider: "ethereum", name: request.name,
        result: null, approvalCommitted: true, state,
    });
    await Promise.resolve();
    assert.equal(outcome?.error?.code, -32603);
    assert.equal(h.window.ethereum.chainId, "0x1");
    assert.equal(h.window.solana.publicKey, null);
    vm.runInContext("globalThis.Uint8Array = OriginalUint8Array", h.context);
    publishSnapshot(h, state);
    assert.equal(h.window.ethereum.chainId, "0x2");
    assert.equal(h.window.solana.publicKey.toString(), firstSolanaKey);
});

for (const inheritedFlag of ["true", "throwing getter"]) {
    test(`prepared snapshots ignore an inherited ignored ${inheritedFlag}`, async () => {
        const h = inpageHarness();
        vm.runInContext(inheritedFlag === "true"
            ? "Object.prototype.ignored = true"
            : `Object.defineProperty(Object.prototype, "ignored", {
                get() { throw new Error("Inherited ignored accessed"); },
            })`, h.context);
        const state = pageSnapshot({chainId: "0x2", publicKey: firstSolanaKey, ethereum: 1, solana: 1});
        publishSnapshot(h, state);
        assert.equal(h.window.ethereum.chainId, "0x2");
        assert.equal(h.window.solana.publicKey.toString(), firstSolanaKey);
        assert.equal(await h.window.ethereum.request({method: "eth_chainId"}), "0x2");
        publishSnapshot(h, pageSnapshot());
        assert.equal(h.window.ethereum.chainId, "0x2");
        assert.equal(h.window.solana.publicKey.toString(), firstSolanaKey);
    });
}
