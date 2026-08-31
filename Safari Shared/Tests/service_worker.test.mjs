// ∅ 2026 lil org

import assert from "node:assert/strict";
import {webcrypto} from "node:crypto";
import {readFile} from "node:fs/promises";
import test from "node:test";
import vm from "node:vm";

const [wireSource, workerSource] = await Promise.all([
    readFile(new URL("../Resources/bridge_wire.js", import.meta.url), "utf8"),
    readFile(new URL("../Resources/service_worker.js", import.meta.url), "utf8"),
]);
const requestToken = "123e4567-e89b-12d3-a456-426614174000";
const attempt = "00000001000000020000000300000004";
const admissionDeadline = 1_700_000_900_000;
const firstSolanaPublicKey = "11111111111111111111111111111111";
const secondSolanaPublicKey = "So11111111111111111111111111111111111111112";

test("configuration tab queries use a shorter best-effort deadline", () => {
    const transportTimeout = Number(workerSource.match(
        /const TRANSPORT_TIMEOUT = (\d+);/
    )[1]);
    const tabQueryTimeout = Number(workerSource.match(
        /const TAB_QUERY_TIMEOUT = (\d+);/
    )[1]);
    assert.equal(tabQueryTimeout, 1000);
    assert.ok(tabQueryTimeout < transportTimeout);
});

function clone(value) {
    return typeof value === "undefined" ? undefined : JSON.parse(JSON.stringify(value));
}

function makeHarness({
    storage = new Map,
    storageGet,
    native,
    localizedMessages = {},
    openPopupMissing = false,
    openPopupRejects = false,
    privateBrowsing = false,
    queryTabs,
    runtimeSendMessage,
    scheduleTimeout,
    sendTabMessage,
    tabs = [{id: 3}, {id: 4}],
} = {}) {
    const nativeMessages = [];
    const badgeTexts = [];
    const popupCalls = [];
    const runtimeMessages = [];
    const tabMessages = [];
    const storageWrites = [];
    const storageRemovals = [];
    const timerDelays = [];
    let tabQueries = 0;
    let installedListener;
    let listener;
    let startupListener;
    const browser = {
        runtime: {
            id: "extension-id",
            getURL(path) { return `safari-web-extension://extension-id/${path}`; },
            onInstalled: {addListener(value) { installedListener = value; }},
            onMessage: {addListener(value) { listener = value; }},
            onStartup: {addListener(value) { startupListener = value; }},
            sendNativeMessage(application, message) {
                nativeMessages.push({application, message: clone(message)});
                return Promise.resolve(native?.(message));
            },
            sendMessage(message) {
                runtimeMessages.push(clone(message));
                return runtimeSendMessage
                    ? Promise.resolve().then(() => runtimeSendMessage(message))
                    : Promise.resolve();
            },
        },
        i18n: {
            getMessage(key) { return localizedMessages[key] || ""; },
        },
        storage: {
            local: {
                get(keys) {
                    const values = {};
                    for (const key of Array.isArray(keys) ? keys : [keys]) {
                        if (storage.has(key)) { values[key] = clone(storage.get(key)); }
                    }
                    return storageGet
                        ? Promise.resolve(storageGet(keys, values))
                        : Promise.resolve(values);
                },
                set(values) {
                    storageWrites.push(clone(values));
                    for (const [key, value] of Object.entries(values)) {
                        storage.set(key, clone(value));
                    }
                    return Promise.resolve();
                },
                remove(key) {
                    storageRemovals.push(key);
                    storage.delete(key);
                    return Promise.resolve();
                },
            },
        },
        action: {
            setBadgeText(value) {
                badgeTexts.push(value.text);
                return Promise.resolve();
            },
            openPopup() {
                popupCalls.push(true);
                return openPopupRejects
                    ? Promise.reject(new Error("popup unavailable"))
                    : Promise.resolve();
            },
        },
        tabs: {
            query() {
                tabQueries += 1;
                return queryTabs ? Promise.resolve(queryTabs()) : Promise.resolve(tabs);
            },
            sendMessage(id, message) {
                tabMessages.push({id, message: clone(message)});
                return sendTabMessage
                    ? Promise.resolve(sendTabMessage(id, message))
                    : Promise.resolve();
            },
        },
    };
    if (openPopupMissing) { delete browser.action.openPopup; }
    const context = vm.createContext({
        browser,
        crypto: webcrypto,
        console,
        importScripts(name) {
            assert.equal(name, "bridge_wire.js");
            new vm.Script(wireSource).runInContext(context);
        },
        Map,
        Object,
        Promise,
        Set,
        URL,
        clearTimeout,
        setTimeout(callback, delay) {
            timerDelays.push(delay);
            return scheduleTimeout
                ? scheduleTimeout(callback, delay)
                : globalThis.setTimeout(callback, delay);
        },
    });
    new vm.Script(workerSource).runInContext(context);
    const defaultSender = {
        url: "https://wallet.example/dapp",
        tab: {
            id: 9,
            url: "https://wallet.example/dapp",
            favIconUrl: "https://wallet.example/icon.png",
            incognito: privateBrowsing,
        },
    };
    return {
        badgeTexts,
        nativeMessages,
        popupCalls,
        runtimeMessages,
        storage,
        storageRemovals,
        storageWrites,
        tabMessages,
        tabQueries() { return tabQueries; },
        timerDelays,
        install(details) {
            return installedListener(details);
        },
        startup() {
            return startupListener();
        },
        dispatch(request, sender = defaultSender) {
            return new Promise(resolve => {
                assert.equal(listener(request, sender, resolve), true);
            });
        },
    };
}

async function settle() {
    for (let index = 0; index < 20; index += 1) { await Promise.resolve(); }
}

function request(id = 7, overrides = {}) {
    const {message: messageOverrides = {}, ...requestOverrides} = overrides;
    return {
        admissionDeadline,
        subject: "message-to-wallet",
        message: {
            id,
            name: "requestAccounts",
            provider: "ethereum",
            body: {address: "", chainId: "0x1"},
            ...messageOverrides,
        },
        host: "wallet.example",
        configurationKey: "https://wallet.example",
        enqueueAttempt: attempt,
        workflowVersion: 3,
        ...requestOverrides,
    };
}

function nativeAcknowledgement(
    id,
    revisions = {ethereum: 0, solana: 0},
    approvalRequired = true
) {
    return {id, requestToken, approvalRequired, revisions};
}

test("registers one production listener and ignores malformed envelopes", async () => {
    const harness = makeHarness();
    assert.equal(await harness.dispatch(null), undefined);
    assert.equal(harness.nativeMessages.length, 0);
});

test("updates persist recovery until the next browser startup", async () => {
    const harness = makeHarness();
    harness.install({reason: "install"});
    harness.install({reason: "browser_update"});
    harness.install(null);
    await settle();
    assert.equal(harness.storage.has("workflowUpdateRecoveryNeeded"), false);
    assert.equal(harness.tabQueries(), 0);

    harness.install({reason: "update"});
    await settle();
    assert.equal(harness.storage.get("workflowUpdateRecoveryNeeded"), true);
    assert.deepEqual(harness.storageWrites, [{workflowUpdateRecoveryNeeded: true}]);
    assert.equal(harness.tabQueries(), 0);

    harness.startup();
    await settle();
    assert.equal(harness.storage.has("workflowUpdateRecoveryNeeded"), false);
    assert.deepEqual(harness.storageRemovals, ["workflowUpdateRecoveryNeeded"]);
    assert.equal(harness.tabQueries(), 0);
});

test("stamps trusted sender identity and preserves native-owned revisions", async () => {
    const harness = makeHarness({native: () => nativeAcknowledgement(
        7,
        {ethereum: 4, solana: 5}
    )});
    const response = await harness.dispatch(request());
    assert.deepEqual(clone(response), {
        id: 7,
        requestToken,
        approvalRequired: true,
        revisions: {ethereum: 4, solana: 5},
    });
    assert.deepEqual(harness.nativeMessages[0].message, {
        admissionDeadline,
        id: 7,
        name: "requestAccounts",
        provider: "ethereum",
        body: {address: "", chainId: "0x1"},
        favicon: "https://wallet.example/icon.png",
        host: "wallet.example",
        configurationKey: "https://wallet.example",
        revisions: {ethereum: 0, solana: 0},
        enqueueAttempt: attempt,
        workflowVersion: 3,
        __bwPrivateBrowsing: false,
    });
    assert.deepEqual(harness.badgeTexts, ["•"]);
    assert.equal(harness.popupCalls.length, 1);
    assert.deepEqual(harness.runtimeMessages, [{
        subject: "pendingRequestAvailable",
        workflowVersion: 3,
    }]);
});

test("broadcasts queued approvals when the popup cannot open", async () => {
    for (const options of [
        {openPopupMissing: true},
        {openPopupRejects: true},
    ]) {
        const harness = makeHarness({
            ...options,
            native: () => nativeAcknowledgement(7),
        });
        assert.equal((await harness.dispatch(request())).requestToken, requestToken);
        await settle();
        assert.deepEqual(harness.runtimeMessages, [{
            subject: "pendingRequestAvailable",
            workflowVersion: 3,
        }]);
    }
});

test("receiving a pending-request notification does not rebroadcast it", async () => {
    const harness = makeHarness();
    await harness.dispatch({
        subject: "pendingRequestAvailable",
        workflowVersion: 3,
    }, {});
    assert.equal(harness.popupCalls.length, 1);
    assert.deepEqual(harness.runtimeMessages, []);
});

test("returns current configuration immediately for stale account-bound operations", async () => {
    const harness = makeHarness({native: () => {
        throw new Error("must not reach native");
    }});
    const response = await harness.dispatch(request(8, {message: {
        name: "signMessage",
        body: {
            address: "0x0000000000000000000000000000000000000001",
            chainId: "0x1",
        },
    }}));
    assert.equal(response.id, 8);
    assert.equal(response.name, "signMessage");
    assert.equal(response.provider, "ethereum");
    assert.equal(response.errorCode, 4100);
    assert.deepEqual(clone(response.latestConfigurations), []);
    assert.equal(harness.nativeMessages.length, 0);
});

test("forwards an account-bound operation with current stored authorization", async () => {
    const address = "0x0000000000000000000000000000000000000001";
    const storage = new Map([["wallet.example", {
        latestConfigurations: [{
            provider: "ethereum",
            chainId: "0x1",
            results: [address],
        }],
        revisions: {ethereum: 2, solana: 0},
        workflowVersion: 3,
    }]]);
    const harness = makeHarness({
        storage,
        native: () => nativeAcknowledgement(8, {ethereum: 2, solana: 0}),
    });
    const response = await harness.dispatch(request(8, {message: {
        name: "signMessage",
        body: {address, chainId: "0x1"},
    }}));
    assert.equal(response.requestToken, requestToken);
    assert.equal(harness.nativeMessages.at(-1).message.body.address, address);
});

test("allows disconnected non-signing Ethereum methods through to native", async () => {
    for (const name of ["addEthereumChain", "switchEthereumChain", "ecRecover"]) {
        const harness = makeHarness({native: message => ({
            id: message.id,
            name: message.name,
            provider: "ethereum",
            result: "ok",
            ...(name === "ecRecover" ? {} : {chainId: "0x1"}),
        })});
        const response = await harness.dispatch(request(30, {message: {
            name,
            body: {address: "", chainId: "0x1"},
        }}));
        assert.equal(response.result, "ok", name);
        assert.equal(harness.nativeMessages.at(-1).message.name, name);
    }
});

test("rejects account-bearing chain mutations without stored authorization", async () => {
    const address = "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    for (const [id, name] of [
        [32, "addEthereumChain"],
        [33, "switchEthereumChain"],
    ]) {
        const harness = makeHarness({native: () => {
            throw new Error("must not reach native");
        }});
        const response = await harness.dispatch(request(id, {message: {
            name,
            body: {
                address,
                chainId: "0x1",
                object: {chainId: "0x2"},
            },
        }}));

        assert.equal(response.errorCode, 4100, name);
        assert.deepEqual(clone(response.latestConfigurations), [], name);
        assert.equal(harness.nativeMessages.length, 0, name);
        assert.deepEqual(harness.storageWrites, [], name);
    }
});

test("chain mutation authorization matches stored addresses case-insensitively", async () => {
    const storedAddress = "0xAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
    const requestedAddress = storedAddress.toLowerCase();
    for (const [id, name] of [
        [34, "addEthereumChain"],
        [35, "switchEthereumChain"],
    ]) {
        const storage = new Map([["https://wallet.example", {
            latestConfigurations: [{
                provider: "ethereum",
                chainId: "0x1",
                results: [storedAddress],
            }],
            revisions: {ethereum: 0, solana: 0},
            workflowVersion: 3,
        }]]);
        const harness = makeHarness({
            storage,
            native: message => nativeAcknowledgement(message.id),
        });
        const response = await harness.dispatch(request(id, {message: {
            name,
            body: {
                address: requestedAddress,
                chainId: "0x1",
                object: {chainId: "0x2"},
            },
        }}));

        assert.equal(response.requestToken, requestToken, name);
        assert.equal(
            harness.nativeMessages.at(-1).message.body.address,
            requestedAddress,
            name
        );
    }
});

test("chain responses preserve only previously trusted Ethereum accounts", async () => {
    const firstAddress = "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const secondAddress = "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    const cases = [
        {id: 36, name: "addEthereumChain", storedResults: [], requestAddress: ""},
        {id: 37, name: "switchEthereumChain", storedResults: [], requestAddress: ""},
        {
            id: 38,
            name: "addEthereumChain",
            storedResults: [firstAddress],
            requestAddress: firstAddress,
        },
        {
            id: 39,
            name: "switchEthereumChain",
            storedResults: [firstAddress],
            requestAddress: firstAddress,
        },
    ];
    for (const item of cases) {
        const latestConfigurations = item.storedResults.length === 0 ? [] : [{
            provider: "ethereum",
            chainId: "0x1",
            results: item.storedResults,
        }];
        const storage = new Map([["https://wallet.example", {
            latestConfigurations,
            revisions: {ethereum: 0, solana: 0},
            workflowVersion: 3,
        }]]);
        const harness = makeHarness({storage, native: message => ({
            id: message.id,
            name: message.name,
            provider: "ethereum",
            chainId: "0x2",
            results: [secondAddress],
        })});
        const response = await harness.dispatch(request(item.id, {message: {
            name: item.name,
            body: {
                address: item.requestAddress,
                chainId: "0x1",
                object: {chainId: "0x2"},
            },
        }}));
        const expectedResults = item.storedResults;

        assert.deepEqual(
            clone(response.latestConfigurations[0].results),
            expectedResults,
            item.name
        );
        assert.deepEqual(clone(response.results), expectedResults, item.name);
        assert.deepEqual(
            storage.get("https://wallet.example").latestConfigurations[0].results,
            expectedResults,
            item.name
        );
        assert.equal(
            storage.get("https://wallet.example").latestConfigurations[0].chainId,
            "0x2",
            item.name
        );
    }
});

test("chain replays use current accounts and stale terminal results expose none", async () => {
    const nativeAddress = "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    const currentAddress = "0xcccccccccccccccccccccccccccccccccccccccc";
    for (const item of [
        {chainId: "0x2", expectedError: undefined, expectedResults: [currentAddress]},
        {chainId: "0x3", expectedError: 4100, expectedResults: undefined},
    ]) {
        const storage = new Map([["https://wallet.example", {
            latestConfigurations: [{
                provider: "ethereum",
                chainId: item.chainId,
                results: [currentAddress],
            }],
            revisions: {ethereum: 1, solana: 0},
            workflowVersion: 3,
        }]]);
        const harness = makeHarness({storage, native: message => {
            if (message.subject !== "getResponse") { return undefined; }
            return {
                id: 41,
                name: "switchEthereumChain",
                provider: "ethereum",
                chainId: "0x2",
                results: [nativeAddress],
            };
        }});
        const response = await harness.dispatch({
            subject: "getResponse",
            id: 41,
            configurationKey: "https://wallet.example",
            requestToken,
            revisions: {ethereum: 0, solana: 0},
            workflowVersion: 3,
        });

        assert.equal(response.errorCode, item.expectedError);
        assert.deepEqual(clone(response.results), item.expectedResults);
        assert.deepEqual(
            clone(response.latestConfigurations[0]?.results),
            [currentAddress]
        );
    }
});

test("admission deadlines must be positive safe integers", async () => {
    const invalid = [undefined, 0, -1, 1.5, Number.MAX_SAFE_INTEGER + 1, "1"];
    for (const value of invalid) {
        const message = request(40);
        if (typeof value === "undefined") {
            delete message.admissionDeadline;
        } else {
            message.admissionDeadline = value;
        }
        const harness = makeHarness({native: () => {
            throw new Error("must not reach native");
        }});

        assert.equal(await harness.dispatch(message), undefined);
        assert.equal(harness.nativeMessages.length, 0);
    }
});

test("accepts manual Switch Account only with the content-stamped marker", async () => {
    const message = {
        name: "switchAccount",
        provider: "unknown",
        body: {latestConfigurations: []},
    };
    const harness = makeHarness({native: requestMessage =>
        nativeAcknowledgement(requestMessage.id)});
    assert.equal(await harness.dispatch(request(31, {message})), undefined);
    const response = await harness.dispatch(request(31, {
        manualSwitch: true,
        message,
    }));
    assert.equal(response.requestToken, requestToken);
    assert.equal(harness.nativeMessages.at(-1).message.manualSwitch, undefined);
});

test("lost enqueue replies reuse the same native enqueue attempt after restart", async () => {
    const storage = new Map;
    const seen = [];
    const native = message => {
        seen.push(message.enqueueAttempt);
        return seen.length === 1 ? undefined : nativeAcknowledgement(9);
    };
    assert.equal(await makeHarness({storage, native}).dispatch(request(9)), undefined);
    const response = await makeHarness({storage, native}).dispatch(request(9));
    assert.equal(response.requestToken, requestToken);
    assert.deepEqual(seen, [attempt, attempt]);
    assert.equal(storage.size, 0);
});

test("lost enqueue acknowledgement keeps native revisions across disconnect drift", async () => {
    const admissions = [];
    let admitted;
    const harness = makeHarness({native: message => {
        if (!message.subject) {
            admissions.push(clone(message.revisions));
            if (!admitted) {
                admitted = nativeAcknowledgement(19, message.revisions);
                return undefined;
            }
            return admitted;
        }
        if (message.subject === "getResponse") {
            return {
                id: 19,
                name: "requestAccounts",
                provider: "ethereum",
                configurationToStore: {
                    provider: "ethereum",
                    chainId: "0x1",
                    results: ["0x0000000000000000000000000000000000000001"],
                },
            };
        }
        return undefined;
    }});
    assert.equal(await harness.dispatch(request(19)), undefined);
    await harness.dispatch({
        subject: "disconnect",
        id: 20,
        provider: "ethereum",
        host: "wallet.example",
        configurationKey: "https://wallet.example",
        workflowVersion: 3,
    });
    const acknowledgement = await harness.dispatch(request(19));
    assert.deepEqual(clone(acknowledgement.revisions), {
        ethereum: 0,
        solana: 0,
    });
    assert.deepEqual(admissions, [
        {ethereum: 0, solana: 0},
        {ethereum: 1, solana: 0},
    ]);
    assert.equal(admitted.requestToken, acknowledgement.requestToken);

    const response = await harness.dispatch({
        subject: "getResponse",
        id: 19,
        configurationKey: "https://wallet.example",
        requestToken,
        revisions: acknowledgement.revisions,
        workflowVersion: 3,
    });
    assert.equal(response.errorCode, 4100);
    assert.deepEqual(clone(response.latestConfigurations), []);
});

test("reads, applies, and retains a native response", async () => {
    const storage = new Map;
    const native = message => {
        if (message.subject === "getResponse") {
            return {
                id: 10,
                name: "requestAccounts",
                provider: "ethereum",
                chainId: "0x1",
                results: ["0x0000000000000000000000000000000000000001"],
                configurationToStore: {
                    provider: "ethereum",
                    chainId: "0x1",
                    results: ["0x0000000000000000000000000000000000000001"],
                },
            };
        }
        return nativeAcknowledgement(10);
    };
    const harness = makeHarness({storage, native});
    const acknowledgement = await harness.dispatch(request(10));
    const response = await harness.dispatch({
        subject: "getResponse",
        id: 10,
        configurationKey: "https://wallet.example",
        requestToken,
        revisions: acknowledgement.revisions,
        workflowVersion: 3,
    });
    assert.equal(response.configurationToStore, undefined);
    assert.equal(response.latestConfigurations[0].results.length, 1);
    assert.deepEqual(clone(response.revisions), {ethereum: 1, solana: 0});
    assert.equal(storage.get("https://wallet.example").workflowVersion, 3);
    assert.deepEqual(storage.get("https://wallet.example").revisions, {
        ethereum: 1,
        solana: 0,
    });
});

test("malformed native configuration mutations fail closed before storage", async () => {
    const harness = makeHarness({native: message => message.subject === "getResponse" ? {
        id: 25,
        name: "requestAccounts",
        provider: "ethereum",
        results: ["0x0000000000000000000000000000000000000001"],
        configurationToStore: {
            provider: "ethereum",
            chainId: "invalid",
            results: ["0x0000000000000000000000000000000000000001"],
        },
    } : undefined});
    const response = await harness.dispatch({
        subject: "getResponse",
        id: 25,
        configurationKey: "https://wallet.example",
        requestToken,
        revisions: {ethereum: 0, solana: 0},
        workflowVersion: 3,
    });

    assert.equal(response.id, 25);
    assert.equal(response.errorCode, -32603);
    assert.equal(response.result, undefined);
    assert.equal(harness.storage.size, 0);
    assert.deepEqual(harness.storageWrites, []);
    assert.deepEqual(harness.tabMessages, []);
});

test("malformed special-chain responses fail closed before storage", async () => {
    for (const [id, name, configurationToStore] of [
        [26, "addEthereumChain", {
            provider: "ethereum",
            chainId: "0x1",
            results: [],
        }],
        [27, "switchEthereumChain", undefined],
    ]) {
        const harness = makeHarness({native: message => {
            if (message.subject !== "getResponse") { return undefined; }
            return {
                id,
                name,
                provider: "ethereum",
                chainId: "invalid",
                results: [],
                ...(typeof configurationToStore === "undefined"
                    ? {}
                    : {configurationToStore}),
            };
        }});
        const response = await harness.dispatch({
            subject: "getResponse",
            id,
            configurationKey: "https://wallet.example",
            requestToken,
            revisions: {ethereum: 0, solana: 0},
            workflowVersion: 3,
        });

        assert.equal(response.id, id);
        assert.equal(response.errorCode, -32603);
        assert.equal(harness.storage.size, 0);
        assert.deepEqual(harness.storageWrites, []);
        assert.deepEqual(harness.tabMessages, []);
    }
});

test("invalid Solana configuration mutations fail closed before storage", async () => {
    const harness = makeHarness({native: message => {
        if (message.subject !== "getResponse") { return undefined; }
        return {
            id: 28,
            name: "connect",
            provider: "solana",
            publicKey: firstSolanaPublicKey,
            configurationToStore: {
                provider: "solana",
                publicKey: "public-key",
            },
        };
    }});
    const response = await harness.dispatch({
        subject: "getResponse",
        id: 28,
        configurationKey: "https://wallet.example",
        requestToken,
        revisions: {ethereum: 0, solana: 0},
        workflowVersion: 3,
    });

    assert.equal(response.id, 28);
    assert.equal(response.errorCode, -32603);
    assert.equal(harness.storage.size, 0);
    assert.deepEqual(harness.storageWrites, []);
    assert.deepEqual(harness.tabMessages, []);
});

test("replays an already-applied response without advancing revisions again", async () => {
    const storage = new Map;
    const native = message => message.subject === "getResponse" ? {
        id: 21,
        name: "requestAccounts",
        provider: "ethereum",
        configurationToStore: {
            provider: "ethereum",
            chainId: "0x1",
            results: ["0x0000000000000000000000000000000000000001"],
        },
    } : nativeAcknowledgement(21);
    const harness = makeHarness({storage, native});
    const acknowledgement = await harness.dispatch(request(21));
    const read = {
        subject: "getResponse",
        id: 21,
        configurationKey: "https://wallet.example",
        requestToken,
        revisions: acknowledgement.revisions,
        workflowVersion: 3,
    };

    const first = await harness.dispatch(read);
    const replay = await harness.dispatch(read);
    assert.deepEqual(
        clone(replay.latestConfigurations),
        clone(first.latestConfigurations)
    );
    assert.equal(replay.__bigWalletSuppressProviderUpdate, undefined);
    assert.deepEqual(storage.get("https://wallet.example").revisions, {
        ethereum: 1,
        solana: 0,
    });
});

test("popup applies a completed response without consuming its later content replay", async () => {
    const storage = new Map;
    const native = message => message.subject === "getResponse" ? {
        id: 23,
        name: "requestAccounts",
        provider: "ethereum",
        configurationToStore: {
            provider: "ethereum",
            chainId: "0x1",
            results: ["0x0000000000000000000000000000000000000001"],
        },
    } : undefined;
    const harness = makeHarness({storage, native});
    const apply = {
        subject: "applyCompletedResponse",
        id: 23,
        host: "wallet.example",
        configurationKey: "https://wallet.example",
        requestToken,
        revisions: {ethereum: 0, solana: 0},
        workflowVersion: 3,
    };
    const popupSender = {
        id: "extension-id",
        url: "safari-web-extension://extension-id/popup.html",
    };

    assert.equal(await harness.dispatch(apply), undefined);
    assert.equal(await harness.dispatch({...apply, extra: true}, popupSender), undefined);
    assert.equal(harness.nativeMessages.length, 0);
    assert.deepEqual(clone(await harness.dispatch(apply, popupSender)), {
        applied: true,
    });
    assert.deepEqual(storage.get("https://wallet.example").revisions, {
        ethereum: 1,
        solana: 0,
    });
    const replay = await harness.dispatch({
        subject: "getResponse",
        id: 23,
        configurationKey: "https://wallet.example",
        requestToken,
        revisions: {ethereum: 0, solana: 0},
        workflowVersion: 3,
    });
    assert.equal(replay.error, undefined);
    assert.equal(replay.latestConfigurations[0].results.length, 1);
    assert.deepEqual(storage.get("https://wallet.example").revisions, {
        ethereum: 1,
        solana: 0,
    });
    assert.deepEqual(harness.nativeMessages.map(value => value.message.subject), [
        "getResponse",
        "getResponse",
    ]);
});

test("popup receives an exact missing completed response", async () => {
    const harness = makeHarness({
        native: message => message.subject === "getResponse"
            ? {id: 24, missing: true}
            : undefined,
    });
    const request = {
        subject: "applyCompletedResponse",
        id: 24,
        host: "wallet.example",
        configurationKey: "https://wallet.example",
        requestToken,
        revisions: {ethereum: 0, solana: 0},
        workflowVersion: 3,
    };
    const popupSender = {
        id: "extension-id",
        url: "safari-web-extension://extension-id/popup.html",
    };

    assert.deepEqual(clone(await harness.dispatch(request, popupSender)), {
        id: 24,
        missing: true,
    });
    assert.deepEqual(clone(await harness.dispatch({
        subject: "getResponse",
        id: 24,
        configurationKey: "https://wallet.example",
        requestToken,
        revisions: {ethereum: 0, solana: 0},
        workflowVersion: 3,
    })), {id: 24, missing: true});
});

test("response reads require the originating tab identity", async () => {
    const harness = makeHarness({native: () => {
        throw new Error("must not reach native");
    }});
    const wrongSender = {
        url: "https://other.example/dapp",
        tab: {id: 2, url: "https://other.example/dapp", incognito: false},
    };
    assert.equal(await harness.dispatch({
        subject: "getResponse",
        id: 10,
        configurationKey: "https://wallet.example",
        requestToken,
        revisions: {ethereum: 0, solana: 0},
        workflowVersion: 3,
    }, wrongSender), undefined);
    assert.equal(harness.nativeMessages.length, 0);
});

test("disconnect revisions fence a stale authorization response", async () => {
    const native = message => message.subject === "getResponse" ? {
        id: 11,
        name: "requestAccounts",
        provider: "ethereum",
        configurationToStore: {
            provider: "ethereum",
            chainId: "0x1",
            results: ["0x0000000000000000000000000000000000000001"],
        },
    } : nativeAcknowledgement(11);
    const harness = makeHarness({native});
    const acknowledgement = await harness.dispatch(request(11));
    await harness.dispatch({
        subject: "disconnect",
        id: 12,
        provider: "ethereum",
        host: "wallet.example",
        configurationKey: "https://wallet.example",
        workflowVersion: 3,
    });
    const response = await harness.dispatch({
        subject: "getResponse",
        id: 11,
        configurationKey: "https://wallet.example",
        requestToken,
        revisions: acknowledgement.revisions,
        workflowVersion: 3,
    });
    assert.equal(response.errorCode, 4100);
    assert.equal(response.__bigWalletSuppressProviderUpdate, undefined);
    assert.deepEqual(clone(response.latestConfigurations), []);
    assert.deepEqual(
        harness.storage.get("https://wallet.example").latestConfigurations,
        []
    );
});

test("a committed approval settles without overwriting a later disconnect", async () => {
    const address = "0x0000000000000000000000000000000000000001";
    const storage = new Map([["https://wallet.example", {
        latestConfigurations: [{
            provider: "ethereum",
            chainId: "0x1",
            results: [address],
        }],
        revisions: {ethereum: 0, solana: 0},
        workflowVersion: 3,
    }]]);
    const harness = makeHarness({
        storage,
        native: message => message.subject === "getResponse" ? {
            id: 49,
            name: "requestAccounts",
            provider: "ethereum",
            results: [address],
            configurationToStore: {
                provider: "ethereum",
                chainId: "0x1",
                results: [address],
            },
            __bwApprovalCommitted: true,
        } : undefined,
    });
    await harness.dispatch({
        subject: "disconnect",
        id: 50,
        provider: "ethereum",
        host: "wallet.example",
        configurationKey: "https://wallet.example",
        workflowVersion: 3,
    });
    const response = await harness.dispatch({
        subject: "getResponse",
        id: 49,
        configurationKey: "https://wallet.example",
        requestToken,
        revisions: {ethereum: 0, solana: 0},
        workflowVersion: 3,
    });

    assert.equal(response.error, undefined);
    assert.deepEqual(response.results, [address]);
    assert.equal(response.__bwApprovalCommitted, true);
    assert.equal(response.__bigWalletSuppressProviderUpdate, undefined);
    assert.deepEqual(clone(response.latestConfigurations), []);
    assert.deepEqual(clone(response.revisions), {ethereum: 1, solana: 0});
    assert.deepEqual(storage.get("https://wallet.example"), {
        latestConfigurations: [],
        revisions: {ethereum: 1, solana: 0},
        workflowVersion: 3,
    });
});

test("committed multi-provider drift preserves only the drifted provider", async () => {
    const ethereum = "0x0000000000000000000000000000000000000001";
    const nextEthereum = "0x0000000000000000000000000000000000000002";
    const storage = new Map([["https://wallet.example", {
        latestConfigurations: [
            {provider: "ethereum", chainId: "0x1", results: [ethereum]},
            {provider: "solana", publicKey: firstSolanaPublicKey},
        ],
        revisions: {ethereum: 0, solana: 0},
        workflowVersion: 3,
    }]]);
    const response = {
        id: 51,
        name: "switchAccount",
        provider: "multiple",
        bodies: [
            {provider: "ethereum", chainId: "0x1", results: [nextEthereum]},
            {provider: "solana", publicKey: secondSolanaPublicKey},
        ],
        configurationToStore: [
            {provider: "ethereum", chainId: "0x1", results: [nextEthereum]},
            {provider: "solana", publicKey: secondSolanaPublicKey},
        ],
        __bwApprovalCommitted: true,
    };
    const harness = makeHarness({
        storage,
        native: message => message.subject === "getResponse" ? response : undefined,
    });
    await harness.dispatch({
        subject: "disconnect",
        id: 52,
        provider: "ethereum",
        host: "wallet.example",
        configurationKey: "https://wallet.example",
        workflowVersion: 3,
    });
    const applied = await harness.dispatch({
        subject: "getResponse",
        id: 51,
        configurationKey: "https://wallet.example",
        requestToken,
        revisions: {ethereum: 0, solana: 0},
        workflowVersion: 3,
    });

    assert.equal(applied.error, undefined);
    assert.equal(applied.__bigWalletSuppressProviderUpdate, undefined);
    assert.deepEqual(clone(applied.latestConfigurations), [{
        provider: "solana",
        publicKey: secondSolanaPublicKey,
        accountRevision: 1,
        solanaAuthorizationEpoch: 1,
    }]);
    assert.deepEqual(clone(applied.revisions), {ethereum: 1, solana: 1});
    assert.equal(applied.bodies, undefined);
    assert.equal(applied.providersToDisconnect, undefined);
    assert.deepEqual(storage.get("https://wallet.example"), {
        latestConfigurations: [{
            provider: "solana",
            publicKey: secondSolanaPublicKey,
        }],
        revisions: {ethereum: 1, solana: 1},
        workflowVersion: 3,
    });
});

test("noncommitted multi-provider drift remains atomic", async () => {
    const storage = new Map([["https://wallet.example", {
        latestConfigurations: [
            {
                provider: "ethereum",
                chainId: "0x1",
                results: ["0x0000000000000000000000000000000000000001"],
            },
            {provider: "solana", publicKey: firstSolanaPublicKey},
        ],
        revisions: {ethereum: 1, solana: 0},
        workflowVersion: 3,
    }]]);
    const harness = makeHarness({native: message => message.subject === "getResponse" ? {
        id: 53,
        name: "switchAccount",
        provider: "multiple",
        bodies: [],
        configurationToStore: [
            {
                provider: "ethereum",
                chainId: "0x1",
                results: ["0x0000000000000000000000000000000000000002"],
            },
            {provider: "solana", publicKey: secondSolanaPublicKey},
        ],
    } : undefined, storage});
    const response = await harness.dispatch({
        subject: "getResponse",
        id: 53,
        configurationKey: "https://wallet.example",
        requestToken,
        revisions: {ethereum: 0, solana: 0},
        workflowVersion: 3,
    });

    assert.equal(response.errorCode, 4100);
    assert.deepEqual(storage.get("https://wallet.example").revisions, {
        ethereum: 1,
        solana: 0,
    });
    assert.equal(storage.get("https://wallet.example").latestConfigurations[1].publicKey,
        firstSolanaPublicKey);
});

test("one storage lineage serializes a disconnect against response application", async () => {
    const address = "0x0000000000000000000000000000000000000001";
    const storage = new Map([["https://wallet.example", {
        latestConfigurations: [{
            provider: "ethereum",
            chainId: "0x1",
            results: [address],
        }],
        revisions: {ethereum: 0, solana: 0},
        workflowVersion: 3,
    }]]);
    let releaseReads;
    const readBarrier = new Promise(resolve => { releaseReads = resolve; });
    let readCount = 0;
    const harness = makeHarness({
        storage,
        storageGet(_keys, values) {
            readCount += 1;
            return readBarrier.then(() => values);
        },
        native: message => message.subject === "getResponse" ? {
            id: 41,
            name: "requestAccounts",
            provider: "ethereum",
            configurationToStore: {
                provider: "ethereum",
                chainId: "0x1",
                results: [address],
            },
        } : undefined,
    });

    const disconnecting = harness.dispatch({
        subject: "disconnect",
        id: 42,
        provider: "ethereum",
        host: "wallet.example",
        configurationKey: "https://wallet.example",
        workflowVersion: 3,
    });
    await settle();
    assert.equal(readCount, 1);
    const applying = harness.dispatch({
        subject: "getResponse",
        id: 41,
        configurationKey: "https://wallet.example",
        requestToken,
        revisions: {ethereum: 0, solana: 0},
        workflowVersion: 3,
    });
    await settle();
    assert.equal(readCount, 1);
    releaseReads();

    const [disconnectResponse, staleResponse] = await Promise.all([
        disconnecting,
        applying,
    ]);
    assert.equal(disconnectResponse.result, null);
    assert.equal(staleResponse.errorCode, 4100);
    assert.deepEqual(clone(staleResponse.latestConfigurations), []);
    assert.equal(readCount, 2);
    assert.deepEqual(storage.get("https://wallet.example"), {
        latestConfigurations: [],
        revisions: {ethereum: 1, solana: 0},
        workflowVersion: 3,
    });
});

test("same-host HTTP and HTTPS configuration operations share a lineage", async () => {
    let releaseReads;
    const readBarrier = new Promise(resolve => { releaseReads = resolve; });
    let readCount = 0;
    const harness = makeHarness({storageGet(_keys, values) {
        readCount += 1;
        return readBarrier.then(() => values);
    }});
    const httpsOperation = harness.dispatch({
        subject: "disconnect",
        id: 70,
        provider: "ethereum",
        host: "wallet.example",
        configurationKey: "https://wallet.example",
        workflowVersion: 3,
    });
    await settle();
    assert.equal(readCount, 1);

    const httpOperation = harness.dispatch({
        subject: "disconnect",
        id: 72,
        provider: "solana",
        host: "wallet.example",
        configurationKey: "http://wallet.example",
        workflowVersion: 3,
    }, {
        url: "http://wallet.example/dapp",
        tab: {
            id: 10,
            url: "http://wallet.example/dapp",
            incognito: false,
        },
    });
    await settle();
    assert.equal(readCount, 1);

    releaseReads();
    const responses = await Promise.all([httpsOperation, httpOperation]);
    assert.equal(responses[0].result, null);
    assert.equal(responses[1].result, null);
    assert.equal(readCount, 2);
});

test("a hung configuration read does not block an unrelated origin", async () => {
    let releaseWalletRead;
    const walletRead = new Promise(resolve => { releaseWalletRead = resolve; });
    let walletReadStarted = false;
    const harness = makeHarness({storageGet(keys, values) {
        const requested = Array.isArray(keys) ? keys : [keys];
        if (requested.includes("https://wallet.example")) {
            walletReadStarted = true;
            return walletRead.then(() => values);
        }
        return values;
    }});
    let walletSettled = false;
    const walletOperation = harness.dispatch({
        subject: "disconnect",
        id: 74,
        provider: "ethereum",
        host: "wallet.example",
        configurationKey: "https://wallet.example",
        workflowVersion: 3,
    }).then(response => {
        walletSettled = true;
        return response;
    });
    await settle();
    assert.equal(walletReadStarted, true);

    const otherResponse = await harness.dispatch({
        subject: "disconnect",
        id: 76,
        provider: "solana",
        host: "other.example",
        configurationKey: "https://other.example",
        workflowVersion: 3,
    }, {
        url: "https://other.example/dapp",
        tab: {
            id: 11,
            url: "https://other.example/dapp",
            incognito: false,
        },
    });
    assert.equal(otherResponse.result, null);
    assert.equal(walletSettled, false);
    assert.deepEqual(harness.storage.get("https://other.example").revisions, {
        ethereum: 0,
        solana: 1,
    });

    releaseWalletRead();
    assert.equal((await walletOperation).result, null);
});

test("localizes private browsing rejection without forwarding the request", async () => {
    const harness = makeHarness({
        localizedMessages: {
            private_browsing_unsupported: "Localized private browsing error",
        },
        privateBrowsing: true,
    });
    const response = await harness.dispatch(request(13));
    assert.equal(response.errorCode, 4200);
    assert.equal(response.error, "Localized private browsing error");
    assert.equal(harness.nativeMessages.length, 0);
});

test("migrates v2 wrappers while preserving configurations and discarding metadata", async () => {
    const storage = new Map([["wallet.example", {
        latestConfigurations: [{
            provider: "solana",
            publicKey: firstSolanaPublicKey,
        }],
        bridgeState: {
            version: 2,
            revision: 4,
            solanaAuthorizationEpoch: 6,
            admittedAttempts: {obsolete: true},
            appliedResponses: {obsolete: true},
        },
    }]]);
    const harness = makeHarness({storage});
    const response = await harness.dispatch({
        subject: "getLatestConfiguration",
        host: "wallet.example",
        configurationKey: "https://wallet.example",
        workflowVersion: 3,
    });
    assert.equal(response.latestConfigurations[0].publicKey, firstSolanaPublicKey);
    assert.deepEqual(clone(response.revisions), {ethereum: 4, solana: 6});
    assert.equal(storage.has("wallet.example"), false);
    assert.equal(storage.get("https://wallet.example").bridgeState, undefined);
    assert.equal(storage.get("https://wallet.example").workflowVersion, 3);
});

test("canonicalizes positive legacy Ethereum quantities across storage shapes", async () => {
    const cases = [
        {
            expected: "0xa",
            value: [{provider: "ethereum", chainId: "0X000A", results: []}],
        },
        {
            expected: "0xb",
            value: {provider: "ethereum", chainId: "0x000B", results: []},
        },
        {
            expected: "0xc",
            value: {
                latestConfigurations: [{
                    provider: "ethereum",
                    chainId: "0X000C",
                    results: [],
                }],
                bridgeState: {revision: 4, solanaAuthorizationEpoch: 6},
            },
        },
    ];

    for (const item of cases) {
        const storage = new Map([["https://wallet.example", item.value]]);
        const harness = makeHarness({storage});
        const response = await harness.dispatch({
            subject: "getLatestConfiguration",
            host: "wallet.example",
            configurationKey: "https://wallet.example",
            workflowVersion: 3,
        });

        assert.equal(response.latestConfigurations[0].chainId, item.expected);
        assert.equal(
            storage.get("https://wallet.example").latestConfigurations[0].chainId,
            item.expected
        );
        assert.equal(storage.get("https://wallet.example").workflowVersion, 3);
        assert.equal(harness.storageWrites.length, 1);
    }
});

test("legacy zero malformed and over-native-max chains fail closed", async () => {
    const values = [
        [{provider: "ethereum", chainId: "0x0", results: []}],
        {provider: "ethereum", chainId: "invalid", results: []},
        {
            latestConfigurations: [{
                provider: "ethereum",
                chainId: "0x8000000000000000",
                results: [],
            }],
        },
    ];

    for (const value of values) {
        const storage = new Map([["https://wallet.example", value]]);
        const harness = makeHarness({storage});
        const response = await harness.dispatch({
            subject: "getLatestConfiguration",
            host: "wallet.example",
            configurationKey: "https://wallet.example",
            workflowVersion: 3,
        });

        assert.equal(response.configurationReadFailed, true);
        assert.deepEqual(harness.storageWrites, []);
        assert.deepEqual(storage.get("https://wallet.example"), value);
    }
});

test("v3 storage does not normalize noncanonical Ethereum quantities", async () => {
    const value = {
        latestConfigurations: [{
            provider: "ethereum",
            chainId: "0X000A",
            results: [],
        }],
        revisions: {ethereum: 1, solana: 0},
        workflowVersion: 3,
    };
    const storage = new Map([["https://wallet.example", value]]);
    const harness = makeHarness({storage});
    const response = await harness.dispatch({
        subject: "getLatestConfiguration",
        host: "wallet.example",
        configurationKey: "https://wallet.example",
        workflowVersion: 3,
    });

    assert.equal(response.configurationReadFailed, true);
    assert.deepEqual(harness.storageWrites, []);
    assert.deepEqual(storage.get("https://wallet.example"), value);
});

test("trusted popup reads the active tab configuration", async () => {
    const storage = new Map([["https://wallet.example", {
        latestConfigurations: [{
            provider: "solana",
            publicKey: firstSolanaPublicKey,
        }],
        revisions: {ethereum: 0, solana: 2},
        workflowVersion: 3,
    }]]);
    const harness = makeHarness({storage});
    const response = await harness.dispatch({
        subject: "getLatestConfiguration",
        host: "wallet.example",
        configurationKey: "https://wallet.example",
        workflowVersion: 3,
    }, {
        id: "extension-id",
        url: "safari-web-extension://extension-id/popup.html",
    });
    assert.equal(response.latestConfigurations[0].publicKey, firstSolanaPublicKey);
    assert.deepEqual(clone(response.revisions), {ethereum: 0, solana: 2});
});

test("provider revisions are exposed only to an exact trusted popup request", async () => {
    const storage = new Map([["https://wallet.example", {
        latestConfigurations: [],
        revisions: {ethereum: 4, solana: 7},
        workflowVersion: 3,
    }]]);
    const harness = makeHarness({storage});
    const message = {
        subject: "getProviderRevisions",
        host: "wallet.example",
        configurationKey: "https://wallet.example",
        workflowVersion: 3,
    };
    const popupSender = {
        id: "extension-id",
        url: "safari-web-extension://extension-id/popup.html",
    };
    assert.deepEqual(clone(await harness.dispatch(message, popupSender)), {
        revisions: {ethereum: 4, solana: 7},
    });
    assert.equal(await harness.dispatch(message), undefined);
    assert.equal(await harness.dispatch({...message, extra: true}, popupSender), undefined);

    const failed = makeHarness({storageGet() { throw new Error("failed read"); }});
    assert.deepEqual(clone(await failed.dispatch(message, popupSender)), {
        configurationReadFailed: true,
    });
});

test("semantic configuration writes notify only matching-origin normal tabs", async () => {
    const storage = new Map([["https://wallet.example", {
        latestConfigurations: [{
            provider: "ethereum",
            chainId: "0x1",
            results: ["0x0000000000000000000000000000000000000001"],
        }],
        revisions: {ethereum: 2, solana: 0},
        workflowVersion: 3,
    }]]);
    const harness = makeHarness({
        storage,
        tabs: [
            {id: 1, url: "https://wallet.example/first", incognito: false},
            {id: 2, url: "http://wallet.example/second"},
            {id: 3, url: "https://other.example/"},
            {id: 4},
            {id: 5, url: "https://wallet.example/private", incognito: true},
        ],
    });
    await harness.dispatch({
        subject: "disconnect",
        id: 43,
        provider: "ethereum",
        host: "wallet.example",
        configurationKey: "https://wallet.example",
        workflowVersion: 3,
    });
    await settle();
    assert.deepEqual(harness.tabMessages, [{
        id: 1,
        message: {
            subject: "configurationChanged",
            configurationKey: "https://wallet.example",
            latestConfigurations: [],
            revisions: {ethereum: 3, solana: 0},
            workflowVersion: 3,
        },
    }]);
});

test("a blocked tab query keeps its event alive without blocking later storage", async () => {
    let releaseFirstQuery;
    const firstQuery = new Promise(resolve => { releaseFirstQuery = resolve; });
    let queryCount = 0;
    const matchingTabs = [{id: 1, url: "https://wallet.example/page"}];
    const harness = makeHarness({queryTabs() {
        queryCount += 1;
        return queryCount === 1 ? firstQuery : matchingTabs;
    }});
    let firstSettled = false;
    const first = harness.dispatch({
        subject: "disconnect",
        id: 60,
        provider: "ethereum",
        host: "wallet.example",
        configurationKey: "https://wallet.example",
        workflowVersion: 3,
    }).then(response => {
        firstSettled = true;
        return response;
    });
    await settle();
    assert.equal(firstSettled, false);
    assert.deepEqual(harness.storage.get("https://wallet.example").revisions, {
        ethereum: 1,
        solana: 0,
    });

    const second = await harness.dispatch({
        subject: "disconnect",
        id: 62,
        provider: "solana",
        host: "wallet.example",
        configurationKey: "https://wallet.example",
        workflowVersion: 3,
    });
    assert.equal(second.result, null);
    assert.equal(firstSettled, false);
    assert.deepEqual(harness.storage.get("https://wallet.example").revisions, {
        ethereum: 1,
        solana: 1,
    });

    releaseFirstQuery(matchingTabs);
    assert.equal((await first).result, null);
    assert.equal(firstSettled, true);
});

test("a short tab-query timeout returns the persisted mutation", async () => {
    const harness = makeHarness({
        queryTabs: () => new Promise(() => {}),
        scheduleTimeout(callback) {
            queueMicrotask(callback);
            return 1;
        },
    });
    const response = await harness.dispatch({
        subject: "disconnect",
        id: 64,
        provider: "ethereum",
        host: "wallet.example",
        configurationKey: "https://wallet.example",
        workflowVersion: 3,
    });

    assert.equal(response.result, null);
    assert.deepEqual(harness.storage.get("https://wallet.example").revisions, {
        ethereum: 1,
        solana: 0,
    });
    assert.deepEqual(harness.timerDelays, [1000]);
    assert.deepEqual(harness.tabMessages, []);
});

test("a response-ready tab-query timeout completes without delivery", async () => {
    const harness = makeHarness({
        queryTabs: () => new Promise(() => {}),
        scheduleTimeout(callback) {
            queueMicrotask(callback);
            return 1;
        },
    });

    assert.equal(await harness.dispatch({
        subject: "responseReady",
        ids: [65],
        workflowVersion: 3,
    }, {}), undefined);
    assert.deepEqual(harness.timerDelays, [1000]);
    assert.deepEqual(harness.tabMessages, []);
});

test("a hung configuration delivery does not block later broadcasts", async () => {
    const storage = new Map([["https://wallet.example", {
        latestConfigurations: [
            {
                provider: "ethereum",
                chainId: "0x1",
                results: ["0x0000000000000000000000000000000000000001"],
            },
            {provider: "solana", publicKey: firstSolanaPublicKey},
        ],
        revisions: {ethereum: 0, solana: 0},
        workflowVersion: 3,
    }]]);
    let releaseFirstDelivery;
    const firstDelivery = new Promise(resolve => {
        releaseFirstDelivery = resolve;
    });
    let queryCount = 0;
    let deliveryCount = 0;
    const matchingTabs = [{id: 1, url: "https://wallet.example/page"}];
    const harness = makeHarness({
        storage,
        queryTabs() {
            queryCount += 1;
            return matchingTabs;
        },
        sendTabMessage() {
            deliveryCount += 1;
            return deliveryCount === 1 ? firstDelivery : undefined;
        },
    });

    await harness.dispatch({
        subject: "disconnect",
        id: 46,
        provider: "ethereum",
        host: "wallet.example",
        configurationKey: "https://wallet.example",
        workflowVersion: 3,
    });
    await settle();
    await harness.dispatch({
        subject: "disconnect",
        id: 48,
        provider: "solana",
        host: "wallet.example",
        configurationKey: "https://wallet.example",
        workflowVersion: 3,
    });
    await settle();
    assert.equal(queryCount, 2);
    assert.deepEqual(harness.tabMessages.map(value => {
        return value.message.latestConfigurations.map(item => item.provider);
    }), [["solana"], []]);
    assert.deepEqual(harness.tabMessages.map(value => value.message.revisions), [
        {ethereum: 1, solana: 0},
        {ethereum: 1, solana: 1},
    ]);
    assert.deepEqual(storage.get("https://wallet.example").revisions, {
        ethereum: 1,
        solana: 1,
    });

    releaseFirstDelivery();
    await settle();
});

test("a generic Solana 4100 does not mutate authorization", async () => {
    const storage = new Map([["https://wallet.example", {
        latestConfigurations: [{
            provider: "solana",
            publicKey: firstSolanaPublicKey,
        }],
        revisions: {ethereum: 0, solana: 3},
        workflowVersion: 3,
    }]]);
    const harness = makeHarness({
        storage,
        native: message => message.subject === "getResponse" ? {
            id: 44,
            name: "signMessage",
            provider: "solana",
            error: "Unauthorized",
            errorCode: 4100,
        } : undefined,
        tabs: [{id: 1, url: "https://wallet.example/"}],
    });
    const response = await harness.dispatch({
        subject: "getResponse",
        id: 44,
        configurationKey: "https://wallet.example",
        requestToken,
        revisions: {ethereum: 0, solana: 3},
        workflowVersion: 3,
    });
    await settle();
    assert.equal(response.errorCode, 4100);
    assert.deepEqual(storage.get("https://wallet.example").revisions, {
        ethereum: 0,
        solana: 3,
    });
    assert.deepEqual(harness.tabMessages, []);
});

test("ordinary RPC waits for the native client without a relay timer", async () => {
    let resolveRPC;
    const harness = makeHarness({native: message => message.subject === "rpc"
        ? new Promise(resolve => { resolveRPC = resolve; })
        : undefined});
    let settled = false;
    const response = harness.dispatch({
        subject: "rpc",
        id: 45,
        chainId: "0x1",
        body: "{}",
        workflowVersion: 3,
    }).then(value => {
        settled = true;
        return value;
    });
    await settle();
    assert.equal(settled, false);
    assert.deepEqual(harness.timerDelays, []);
    resolveRPC({id: 45, result: "ok"});
    assert.deepEqual(clone(await response), {id: 45, result: "ok"});
});

test("broadcasts response-ready hints and treats badge updates as best effort", async () => {
    const harness = makeHarness();
    await harness.dispatch({
        subject: "responseReady",
        ids: [1, 2],
        workflowVersion: 3,
    }, {});
    assert.deepEqual(harness.tabMessages.map(value => value.id), [3, 4]);
    await harness.dispatch({
        subject: "updatePendingRequestBadge",
        hasPendingRequests: false,
        workflowVersion: 3,
    }, {});
    assert.equal(harness.badgeTexts.at(-1), "");
});
