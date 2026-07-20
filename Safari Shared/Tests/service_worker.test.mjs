// ∅ 2026 lil org

import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import vm from "node:vm";

const source = await readFile(
    new URL("../Resources/service_worker.js", import.meta.url),
    "utf8"
);

function deferred() {
    let resolve;
    let reject;
    const promise = new Promise((resolvePromise, rejectPromise) => {
        resolve = resolvePromise;
        reject = rejectPromise;
    });
    return { promise, reject, resolve };
}

function normalized(value) {
    return JSON.parse(JSON.stringify(value));
}

function makeHarness({ sendNativeMessage, storageGet, storageSet } = {}) {
    const nativeMessages = [];
    let runtimeListener;
    const browser = {
        runtime: {
            onMessage: {
                addListener(listener) {
                    runtimeListener = listener;
                },
            },
            sendNativeMessage(application, message) {
                nativeMessages.push({
                    application,
                    message: normalized(message),
                });
                if (sendNativeMessage) {
                    return sendNativeMessage(application, message);
                }
                return Promise.resolve();
            },
        },
        storage: {
            local: {
                get(key) {
                    if (storageGet) {
                        return storageGet(key);
                    }
                    return Promise.resolve({});
                },
                set(value) {
                    if (storageSet) {
                        return storageSet(value);
                    }
                    return Promise.resolve();
                },
            },
        },
        browserAction: {
            onClicked: {
                addListener() {},
            },
        },
        webNavigation: {
            onBeforeNavigate: {
                addListener() {},
            },
        },
        tabs: {
            executeScript() {
                return Promise.resolve();
            },
            getCurrent(callback) {
                callback(undefined);
            },
            sendMessage() {
                return Promise.resolve();
            },
            update() {
                return Promise.resolve();
            },
        },
    };
    class FixedDate extends Date {
        constructor(...arguments_) {
            if (arguments_.length === 0) {
                super(1_700_000_000_000);
            } else {
                super(...arguments_);
            }
        }

        static now() {
            return 1_700_000_000_000;
        }
    }
    const context = vm.createContext({
        browser,
        Date: FixedDate,
        Math: {
            floor: Math.floor,
            random: () => 0,
        },
    });
    new vm.Script(source, {
        filename: "service_worker.js",
    }).runInContext(context);

    return {
        context,
        evaluate(expression) {
            return new vm.Script(expression).runInContext(context);
        },
        nativeMessages,
        runtimeListener: () => runtimeListener,
    };
}

async function settlePromises() {
    for (let index = 0; index < 10; index += 1) {
        await Promise.resolve();
    }
}

test("registers its production message listener", () => {
    const harness = makeHarness();

    assert.equal(harness.runtimeListener(), harness.context.handleOnMessage);
});

test("skips configurations that cannot use Alchemy", () => {
    const harness = makeHarness();

    harness.context.prewarmAlchemyIfConfigured(undefined);
    harness.context.prewarmAlchemyIfConfigured([]);
    harness.context.prewarmAlchemyIfConfigured({ provider: "unknown" });
    harness.context.prewarmAlchemyIfConfigured({ provider: "solana" });
    harness.context.prewarmAlchemyIfConfigured({
        provider: "solana",
        cluster: "mainnet-beta",
    });
    harness.context.prewarmAlchemyIfConfigured({ provider: "ethereum" });
    harness.context.prewarmAlchemyIfConfigured({
        provider: "ethereum",
        chainId: 1,
    });

    assert.deepEqual(harness.nativeMessages, []);
});

test("sends the exact Ethereum prewarm bridge request", () => {
    const request = deferred();
    const harness = makeHarness({
        sendNativeMessage: () => request.promise,
    });

    harness.context.prewarmAlchemyIfConfigured({
        provider: "ethereum",
        chainId: "0x1",
    });

    assert.deepEqual(harness.nativeMessages, [{
        application: "org.lil.wallet",
        message: {
            id: 1_700_000_000_000,
            subject: "prewarmAlchemy",
            provider: "ethereum",
            chainId: "0x1",
        },
    }]);
});

test("ignores Solana and prewarms the configured Ethereum network", () => {
    const request = deferred();
    const harness = makeHarness({
        sendNativeMessage: () => request.promise,
    });

    harness.context.prewarmAlchemyIfConfigured([
        { provider: "ethereum", chainId: "0x1" },
        { provider: "solana", cluster: "mainnet-beta" },
    ]);

    assert.deepEqual(harness.nativeMessages, [{
        application: "org.lil.wallet",
        message: {
            id: 1_700_000_000_000,
            subject: "prewarmAlchemy",
            provider: "ethereum",
            chainId: "0x1",
        },
    }]);
});

test("deduplicates an active prewarm for the same configuration", () => {
    const request = deferred();
    const harness = makeHarness({
        sendNativeMessage: () => request.promise,
    });
    const configuration = {
        provider: "ethereum",
        chainId: "0x1",
    };

    harness.context.prewarmAlchemyIfConfigured(configuration);
    harness.context.prewarmAlchemyIfConfigured({ ...configuration });

    assert.equal(harness.nativeMessages.length, 1);
});

test("continues forwarding and responding to RPC while prewarm is pending", async () => {
    const prewarmRequest = deferred();
    const harness = makeHarness({
        sendNativeMessage: (_application, message) => {
            if (message.subject === "prewarmAlchemy") {
                return prewarmRequest.promise;
            }
            return Promise.resolve({
                id: message.id,
                result: "0x2a",
            });
        },
    });
    const responses = [];

    harness.context.prewarmAlchemyIfConfigured({
        provider: "ethereum",
        chainId: "0x1",
    });
    const keepsChannelOpen = harness.context.handleOnMessage(
        {
            id: 42,
            subject: "rpc",
            provider: "ethereum",
            chainId: "0x1",
            body: "{\"method\":\"eth_chainId\"}",
        },
        {},
        response => responses.push(normalized(response))
    );
    await settlePromises();

    assert.equal(keepsChannelOpen, true);
    assert.deepEqual(harness.nativeMessages, [
        {
            application: "org.lil.wallet",
            message: {
                id: 1_700_000_000_000,
                subject: "prewarmAlchemy",
                provider: "ethereum",
                chainId: "0x1",
            },
        },
        {
            application: "org.lil.wallet",
            message: {
                id: 42,
                subject: "rpc",
                provider: "ethereum",
                chainId: "0x1",
                body: "{\"method\":\"eth_chainId\"}",
            },
        },
    ]);
    assert.deepEqual(responses, [{
        id: 42,
        result: "0x2a",
    }]);
});

test("keeps only the latest queued Ethereum configuration", async () => {
    const requests = [];
    const harness = makeHarness({
        sendNativeMessage: () => {
            const request = deferred();
            requests.push(request);
            return request.promise;
        },
    });

    harness.context.prewarmAlchemyIfConfigured({
        provider: "ethereum",
        chainId: "0x1",
    });
    harness.context.prewarmAlchemyIfConfigured({
        provider: "ethereum",
        chainId: "0x2",
    });
    harness.context.prewarmAlchemyIfConfigured({
        provider: "ethereum",
        chainId: "0x3",
    });
    requests[0].resolve();
    await settlePromises();

    assert.equal(harness.nativeMessages.length, 2);
    assert.equal(harness.nativeMessages[1].message.chainId, "0x3");
});

test("does not let an active-network observation erase a queued network", async () => {
    const requests = [];
    const harness = makeHarness({
        sendNativeMessage: () => {
            const request = deferred();
            requests.push(request);
            return request.promise;
        },
    });

    harness.context.prewarmAlchemyIfConfigured({
        provider: "ethereum",
        chainId: "0x1",
    });
    harness.context.prewarmAlchemyIfConfigured({
        provider: "ethereum",
        chainId: "0x2",
    });
    harness.context.prewarmAlchemyIfConfigured({
        provider: "ethereum",
        chainId: "0x1",
    });
    requests[0].resolve();
    await settlePromises();

    assert.equal(harness.nativeMessages.length, 2);
    assert.equal(harness.nativeMessages[1].message.chainId, "0x2");
});

test("does not let a stale storage read replace a newer queued network", async () => {
    const storageRead = deferred();
    const requests = [];
    const harness = makeHarness({
        sendNativeMessage: () => {
            const request = deferred();
            requests.push(request);
            return request.promise;
        },
        storageGet: () => storageRead.promise,
    });
    const responses = [];

    harness.context.prewarmAlchemyIfConfigured({
        provider: "ethereum",
        chainId: "0x1",
    });
    harness.context.handleOnMessage(
        {
            subject: "getLatestConfiguration",
            host: "wallet.example",
        },
        {},
        response => responses.push(normalized(response))
    );
    harness.context.storeLatestConfiguration("wallet.example", [
        { provider: "ethereum", chainId: "0x3" },
    ]);
    storageRead.resolve({
        "wallet.example": [
            { provider: "ethereum", chainId: "0x2" },
        ],
    });
    await settlePromises();
    requests[0].resolve();
    await settlePromises();

    assert.deepEqual(responses, [{
        latestConfigurations: [
            { provider: "ethereum", chainId: "0x2" },
        ],
    }]);
    assert.equal(harness.nativeMessages.length, 2);
    assert.equal(harness.nativeMessages[1].message.chainId, "0x3");
});

test("retains generation state only while a configuration read is active", async () => {
    const storageRead = deferred();
    const harness = makeHarness({
        storageGet: () => storageRead.promise,
    });
    const responses = [];

    harness.context.handleOnMessage(
        {
            subject: "getLatestConfiguration",
            host: "wallet.example",
        },
        {},
        response => responses.push(normalized(response))
    );

    assert.equal(
        harness.evaluate("alchemyPrewarmHostStates.size"),
        1
    );
    assert.equal(
        harness.evaluate(
            "alchemyPrewarmHostStates.get('wallet.example').inFlightReadCount"
        ),
        1
    );

    storageRead.resolve({
        "wallet.example": [
            { provider: "solana", cluster: "mainnet-beta" },
        ],
    });
    await settlePromises();

    assert.deepEqual(responses, [{
        latestConfigurations: [
            { provider: "solana", cluster: "mainnet-beta" },
        ],
    }]);
    assert.equal(
        harness.evaluate("alchemyPrewarmHostStates.size"),
        0
    );
});

test("retains generation state until its queued write settles", async () => {
    const storageWrite = deferred();
    const harness = makeHarness({
        storageSet: () => storageWrite.promise,
    });

    harness.context.storeLatestConfiguration("wallet.example", [
        { provider: "solana", cluster: "mainnet-beta" },
    ]);
    await settlePromises();

    assert.equal(
        harness.evaluate("alchemyPrewarmHostStates.size"),
        1
    );
    assert.equal(
        harness.evaluate("latestConfigurationWriteQueues.size"),
        1
    );

    storageWrite.resolve();
    await settlePromises();

    assert.equal(
        harness.evaluate("latestConfigurationWriteQueues.size"),
        0
    );
    assert.equal(
        harness.evaluate("alchemyPrewarmHostStates.size"),
        0
    );
});

test("waits for an already-queued configuration write before prewarming its host", async () => {
    const storageWrite = deferred();
    const requests = [];
    const responseReceived = deferred();
    let storedConfiguration = [
        { provider: "ethereum", chainId: "0x1" },
    ];
    let storageReadCount = 0;
    const harness = makeHarness({
        sendNativeMessage: () => {
            const request = deferred();
            requests.push(request);
            return request.promise;
        },
        storageGet: key => {
            storageReadCount += 1;
            return Promise.resolve({
                [key]: storedConfiguration,
            });
        },
        storageSet: value => {
            return storageWrite.promise.then(() => {
                storedConfiguration = value["wallet.example"];
            });
        },
    });
    const responses = [];

    harness.context.prewarmAlchemyIfConfigured({
        provider: "ethereum",
        chainId: "0x0",
    });
    harness.context.storeLatestConfiguration("wallet.example", [
        { provider: "ethereum", chainId: "0x2" },
    ]);
    harness.context.handleOnMessage(
        {
            subject: "getLatestConfiguration",
            host: "wallet.example",
        },
        {},
        response => {
            responses.push(normalized(response));
            responseReceived.resolve();
        }
    );
    await settlePromises();

    assert.equal(storageReadCount, 0);

    storageWrite.resolve();
    await responseReceived.promise;
    requests[0].resolve();
    await settlePromises();

    assert.deepEqual(responses, [{
        latestConfigurations: [
            { provider: "ethereum", chainId: "0x2" },
        ],
    }]);
    assert.equal(harness.nativeMessages.length, 2);
    assert.equal(harness.nativeMessages[1].message.chainId, "0x2");
});

test("lets an authoritative snapshot replace its host's queued network", async () => {
    const requests = [];
    const harness = makeHarness({
        sendNativeMessage: () => {
            const request = deferred();
            requests.push(request);
            return request.promise;
        },
    });

    harness.context.prewarmAlchemyIfConfigured(
        { provider: "ethereum", chainId: "0x1" },
        "wallet.example"
    );
    harness.context.prewarmAlchemyIfConfigured(
        { provider: "ethereum", chainId: "0x2" },
        "wallet.example"
    );
    harness.context.storeLatestConfiguration("wallet.example", [
        { provider: "ethereum", chainId: "0x1" },
    ]);
    requests[0].resolve();
    await settlePromises();

    assert.equal(harness.nativeMessages.length, 1);
});

test("clears a host's queued network when its full snapshot has no Ethereum", async () => {
    const requests = [];
    const harness = makeHarness({
        sendNativeMessage: () => {
            const request = deferred();
            requests.push(request);
            return request.promise;
        },
    });

    harness.context.prewarmAlchemyIfConfigured(
        { provider: "ethereum", chainId: "0x1" },
        "active.example"
    );
    harness.context.prewarmAlchemyIfConfigured(
        { provider: "ethereum", chainId: "0x2" },
        "disconnected.example"
    );
    harness.context.storeLatestConfiguration("disconnected.example", [
        { provider: "solana", cluster: "mainnet-beta" },
    ]);
    requests[0].resolve();
    await settlePromises();

    assert.equal(harness.nativeMessages.length, 1);
});

test("does not let another host's full snapshot erase a queued network", async () => {
    const requests = [];
    const harness = makeHarness({
        sendNativeMessage: () => {
            const request = deferred();
            requests.push(request);
            return request.promise;
        },
    });

    harness.context.prewarmAlchemyIfConfigured(
        { provider: "ethereum", chainId: "0x1" },
        "active.example"
    );
    harness.context.prewarmAlchemyIfConfigured(
        { provider: "ethereum", chainId: "0x2" },
        "queued.example"
    );
    harness.context.storeLatestConfiguration("other.example", [
        { provider: "solana", cluster: "mainnet-beta" },
    ]);
    requests[0].resolve();
    await settlePromises();

    assert.equal(harness.nativeMessages.length, 2);
    assert.equal(harness.nativeMessages[1].message.chainId, "0x2");
});

test("does not let an incremental Solana update erase queued Ethereum", async () => {
    const requests = [];
    const harness = makeHarness({
        sendNativeMessage: () => {
            const request = deferred();
            requests.push(request);
            return request.promise;
        },
    });

    harness.context.prewarmAlchemyIfConfigured(
        { provider: "ethereum", chainId: "0x1" },
        "active.example"
    );
    harness.context.prewarmAlchemyIfConfigured(
        { provider: "ethereum", chainId: "0x2" },
        "wallet.example"
    );
    harness.context.storeLatestConfiguration("wallet.example", {
        provider: "solana",
        cluster: "mainnet-beta",
    });
    requests[0].resolve();
    await settlePromises();

    assert.equal(harness.nativeMessages.length, 2);
    assert.equal(harness.nativeMessages[1].message.chainId, "0x2");
});

test("clears a host's queued Ethereum network on disconnect", async () => {
    const requests = [];
    const harness = makeHarness({
        sendNativeMessage: () => {
            const request = deferred();
            requests.push(request);
            return request.promise;
        },
    });

    harness.context.prewarmAlchemyIfConfigured(
        { provider: "ethereum", chainId: "0x1" },
        "active.example"
    );
    harness.context.prewarmAlchemyIfConfigured(
        { provider: "ethereum", chainId: "0x2" },
        "disconnected.example"
    );
    const removal = harness.context.removeLatestConfiguration(
        "disconnected.example",
        "ethereum"
    );
    await removal;
    requests[0].resolve();
    await settlePromises();

    assert.equal(harness.nativeMessages.length, 1);
});

test("does not drain a queued network while its disconnect write is pending", async () => {
    const storageWrite = deferred();
    const requests = [];
    const harness = makeHarness({
        sendNativeMessage: () => {
            const request = deferred();
            requests.push(request);
            return request.promise;
        },
        storageSet: () => storageWrite.promise,
    });

    harness.context.prewarmAlchemyIfConfigured(
        { provider: "ethereum", chainId: "0x1" },
        "active.example"
    );
    harness.context.prewarmAlchemyIfConfigured(
        { provider: "ethereum", chainId: "0x2" },
        "disconnected.example"
    );
    const removal = harness.context.removeLatestConfiguration(
        "disconnected.example",
        "ethereum"
    );
    requests[0].resolve();
    await settlePromises();

    assert.equal(harness.nativeMessages.length, 1);

    storageWrite.resolve();
    await removal;
    await settlePromises();

    assert.equal(harness.nativeMessages.length, 1);
});

test("preserves a reconnect queued while an earlier disconnect completes", async () => {
    const requests = [];
    const harness = makeHarness({
        sendNativeMessage: () => {
            const request = deferred();
            requests.push(request);
            return request.promise;
        },
    });

    harness.context.prewarmAlchemyIfConfigured(
        { provider: "ethereum", chainId: "0x1" },
        "active.example"
    );
    harness.context.prewarmAlchemyIfConfigured(
        { provider: "ethereum", chainId: "0x2" },
        "wallet.example"
    );
    const removal = harness.context.removeLatestConfiguration(
        "wallet.example",
        "ethereum"
    );
    harness.context.storeLatestConfiguration("wallet.example", {
        provider: "ethereum",
        chainId: "0x3",
    });
    await removal;
    requests[0].resolve();
    await settlePromises();

    assert.equal(harness.nativeMessages.length, 2);
    assert.equal(harness.nativeMessages[1].message.chainId, "0x3");
});

test("keeps a shared queued network when only one requesting host disconnects", async () => {
    const requests = [];
    const harness = makeHarness({
        sendNativeMessage: () => {
            const request = deferred();
            requests.push(request);
            return request.promise;
        },
    });

    harness.context.prewarmAlchemyIfConfigured(
        { provider: "ethereum", chainId: "0x1" },
        "active.example"
    );
    harness.context.prewarmAlchemyIfConfigured(
        { provider: "ethereum", chainId: "0x2" },
        "first.example"
    );
    harness.context.prewarmAlchemyIfConfigured(
        { provider: "ethereum", chainId: "0x2" },
        "second.example"
    );
    await harness.context.removeLatestConfiguration(
        "first.example",
        "ethereum"
    );
    requests[0].resolve();
    await settlePromises();

    assert.equal(harness.nativeMessages.length, 2);
    assert.equal(harness.nativeMessages[1].message.chainId, "0x2");
});

test("prunes superseded and consumed pending-host state", async () => {
    const requests = [];
    const harness = makeHarness({
        sendNativeMessage: () => {
            const request = deferred();
            requests.push(request);
            return request.promise;
        },
    });

    harness.context.prewarmAlchemyIfConfigured(
        { provider: "ethereum", chainId: "0x1" },
        "active.example"
    );
    harness.context.storeLatestConfiguration("first.example", [
        { provider: "ethereum", chainId: "0x2" },
    ]);
    harness.context.storeLatestConfiguration("second.example", [
        { provider: "ethereum", chainId: "0x3" },
    ]);
    await settlePromises();

    assert.deepEqual(
        normalized(harness.evaluate(
            "[...alchemyPrewarmHostStates.keys()]"
        )),
        ["second.example"]
    );
    assert.equal(
        harness.evaluate("pendingAlchemyPrewarmHosts.size"),
        1
    );

    requests[0].resolve();
    await settlePromises();

    assert.equal(harness.nativeMessages.length, 2);
    assert.equal(harness.nativeMessages[1].message.chainId, "0x3");
    assert.equal(
        harness.evaluate("pendingAlchemyPrewarmHosts.size"),
        0
    );
    assert.equal(
        harness.evaluate("alchemyPrewarmHostStates.size"),
        0
    );
});

test("prunes hundreds of settled hosts without reusing generations", async () => {
    const harness = makeHarness();

    for (let index = 0; index < 500; index += 1) {
        harness.context.storeLatestConfiguration(
            `wallet-${index}.example`,
            [{ provider: "solana", cluster: "mainnet-beta" }]
        );
    }
    await settlePromises();

    assert.equal(
        harness.evaluate("latestConfigurationWriteQueues.size"),
        0
    );
    assert.equal(
        harness.evaluate("alchemyPrewarmHostStates.size"),
        0
    );

    const firstGeneration =
        harness.context.advanceAlchemyPrewarmHostGeneration(
            "reconnected.example"
        );
    harness.context.pruneAlchemyPrewarmHostState(
        "reconnected.example"
    );
    const secondGeneration =
        harness.context.advanceAlchemyPrewarmHostGeneration(
            "reconnected.example"
        );

    assert.ok(secondGeneration > firstGeneration);

    harness.context.pruneAlchemyPrewarmHostState(
        "reconnected.example"
    );
    assert.equal(
        harness.evaluate("alchemyPrewarmHostStates.size"),
        0
    );
});

test("ignores Solana while keeping the latest queued Ethereum configuration", async () => {
    const requests = [];
    const harness = makeHarness({
        sendNativeMessage: () => {
            const request = deferred();
            requests.push(request);
            return request.promise;
        },
    });

    harness.context.prewarmAlchemyIfConfigured({
        provider: "ethereum",
        chainId: "0x1",
    });
    harness.context.prewarmAlchemyIfConfigured({
        provider: "ethereum",
        chainId: "0x2",
    });
    harness.context.prewarmAlchemyIfConfigured({ provider: "solana" });
    harness.context.prewarmAlchemyIfConfigured({
        provider: "ethereum",
        chainId: "0x3",
    });
    requests[0].resolve();
    await settlePromises();

    assert.equal(harness.nativeMessages.length, 2);
    assert.equal(harness.nativeMessages[1].message.provider, "ethereum");
    assert.equal(harness.nativeMessages[1].message.chainId, "0x3");
});

test("drains the pending configuration after native rejection", async () => {
    const requests = [];
    const harness = makeHarness({
        sendNativeMessage: () => {
            const request = deferred();
            requests.push(request);
            return request.promise;
        },
    });

    harness.context.prewarmAlchemyIfConfigured({
        provider: "ethereum",
        chainId: "0x1",
    });
    harness.context.prewarmAlchemyIfConfigured({
        provider: "ethereum",
        chainId: "0x2",
    });
    requests[0].reject(new Error("native bridge unavailable"));
    await settlePromises();

    assert.equal(harness.nativeMessages.length, 2);
    assert.equal(harness.nativeMessages[1].message.chainId, "0x2");
});

test("remains reusable after sendNativeMessage throws synchronously", () => {
    let attempt = 0;
    const harness = makeHarness({
        sendNativeMessage: () => {
            attempt += 1;
            if (attempt === 1) {
                throw new Error("native bridge unavailable");
            }
            return Promise.resolve();
        },
    });
    const configuration = {
        provider: "ethereum",
        chainId: "0x1",
    };

    harness.context.prewarmAlchemyIfConfigured(configuration);
    harness.context.prewarmAlchemyIfConfigured(configuration);

    assert.equal(harness.nativeMessages.length, 2);
});
