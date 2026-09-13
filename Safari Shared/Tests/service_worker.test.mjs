// ∅ 2026 lil org

import assert from "node:assert/strict";
import {webcrypto} from "node:crypto";
import {readFile} from "node:fs/promises";
import test from "node:test";
import vm from "node:vm";
import {deferred, popupElement} from "./test_helpers.mjs";

const [wireSource, workerSource, sharedManifestSource, macManifestSource, popupSource] =
    await Promise.all([
    readFile(new URL("../Resources/bridge_wire.js", import.meta.url), "utf8"),
    readFile(new URL("../Resources/service_worker.js", import.meta.url), "utf8"),
    readFile(new URL("../Resources/manifest.json", import.meta.url), "utf8"),
    readFile(new URL("../../Safari macOS/Resources/manifest.json", import.meta.url), "utf8"),
    readFile(new URL("../Resources/popup.js", import.meta.url), "utf8"),
    ]);
const requestToken = "123e4567-e89b-12d3-a456-426614174000";
const reviewToken = "123e4567-e89b-12d3-a456-426614174001";
const attempt = "00000001000000020000000300000004";
const admissionDeadline = 1_700_000_900_000;
const firstSolanaPublicKey = "11111111111111111111111111111111";
const secondSolanaPublicKey = "So11111111111111111111111111111111111111112";
const wireContext = vm.createContext({URL, crypto: webcrypto, clearTimeout, setTimeout});
new vm.Script(wireSource).runInContext(wireContext);
const packagedBuildVersion = wireContext.BigWalletBridgeWire.BUILD_VERSION;
assert.match(packagedBuildVersion, /^.+\+[0-9]+$/);
const packagedMarketingVersion = packagedBuildVersion.split("+")[0];
const previousBuildVersion = packagedBuildVersion.replace(
    /[0-9]+$/,
    value => String(Math.max(0, Number(value) - 1))
);
const recoveryAlarmName = "manualSwitchRecovery";
const approvalLeaseStoragePrefix = makeHarness().read("APPROVAL_LEASE_STORAGE_PREFIX");
assert.equal(typeof approvalLeaseStoragePrefix, "string");

test("toolbar relays use distinct probe and manual-switch deadlines", () => {
    const harness = makeHarness();
    const transportTimeout = harness.read("TRANSPORT_TIMEOUT");
    const tabQueryTimeout = harness.read("TAB_QUERY_TIMEOUT");
    const nativeOperationTimeout = harness.read("NATIVE_OPERATION_TIMEOUT");
    const approvalExecutionTimeout = harness.read("APPROVAL_EXECUTION_TIMEOUT");
    const approvalLeaseGrace = harness.read("APPROVAL_LEASE_GRACE");
    assert.equal(tabQueryTimeout, 1000);
    assert.ok(tabQueryTimeout < transportTimeout);
    assert.equal(harness.read("MANUAL_SWITCH_INTENT_TIMEOUT"), 10_000);
    assert.equal(approvalExecutionTimeout, 150_000);
    assert.equal(approvalLeaseGrace, 10_000);
    assert.ok(approvalExecutionTimeout + approvalLeaseGrace <
        nativeOperationTimeout);
    assert.equal(nativeOperationTimeout, 180_000);
    assert.ok(nativeOperationTimeout > 120_000);
});

test("manual-switch recovery includes alarm permission", () => {
    const sharedManifest = JSON.parse(sharedManifestSource);
    const manifest = JSON.parse(macManifestSource);
    assert.equal(sharedManifest.action.default_popup, "popup.html");
    assert.equal(sharedManifest.permissions.includes("alarms"), true);
    assert.equal(manifest.action.default_popup, undefined);
    assert.equal(manifest.permissions.includes("alarms"), true);
});

function clone(value) {
    return typeof value === "undefined" ? undefined : JSON.parse(JSON.stringify(value));
}

function providerStateWrites(harness) {
    return harness.storageWrites.filter(values =>
        Object.keys(values).some(key => !key.startsWith(
            approvalLeaseStoragePrefix
        ))
    );
}

function isResponseRead(message) {
    return message.subject === "getResponse" ||
        message.subject === "getManualSwitchResponse";
}

function makeHarness({
    acknowledgeResponse = message => ({id: message.id, acknowledged: true}),
    cancelTimeout,
    alarms = new Map,
    clearAlarm,
    configuredPopup = true,
    createAlarm,
    getAlarm,
    dateNow,
    storage = new Map,
    storageGet,
    native,
    recoveryNative,
    localizedMessages = {},
    openPopupMissing = false,
    openPopupRejects = false,
    privateBrowsing = false,
    queryTabs,
    runtimeSendMessage,
    scheduleTimeout,
    sendTabMessage,
    tabs = [{id: 3}, {id: 4}],
    storageSet,
    workerPrivateBrowsing = false,
} = {}) {
    const nativeMessages = [];
    const recoveryMessages = [];
    const alarmGets = [];
    const alarmCreates = [];
    const alarmClears = [];
    const badgeTexts = [];
    const popupCalls = [];
    const runtimeMessages = [];
    const tabMessages = [];
    const storageWrites = [];
    const storageRemovals = [];
    const timerDelays = [];
    const timers = new Map;
    let tabQueries = 0;
    let alarmListener;
    let installedListener;
    let listener;
    let startupListener;
    let toolbarListener;
    const browser = {
        extension: {inIncognitoContext: workerPrivateBrowsing},
        alarms: {
            get(name) {
                alarmGets.push(name);
                return Promise.resolve(getAlarm
                    ? getAlarm(name, clone(alarms.get(name)))
                    : clone(alarms.get(name)));
            },
            clear(name) {
                alarmClears.push(name);
                return Promise.resolve(clearAlarm ? clearAlarm(name) : true)
                    .then(result => { alarms.delete(name); return result; });
            },
            create(name, options) {
                alarmCreates.push({name, options: clone(options)});
                return Promise.resolve(createAlarm ? createAlarm(name, clone(options)) : undefined)
                    .then(() => { alarms.set(name, {name, ...clone(options)}); });
            },
            onAlarm: {addListener(value) { alarmListener = value; }},
        },
        runtime: {
            id: "extension-id",
            getManifest() {
                return configuredPopup
                    ? {
                        action: {default_popup: "popup.html"},
                        version: packagedMarketingVersion,
                    }
                    : {action: {}, version: packagedMarketingVersion};
            },
            getURL(path) { return `safari-web-extension://extension-id/${path}`; },
            onInstalled: {addListener(value) { installedListener = value; }},
            onMessage: {addListener(value) { listener = value; }},
            onStartup: {addListener(value) { startupListener = value; }},
            sendNativeMessage(application, message) {
                if (message.subject === "getManualSwitchRequests") {
                    recoveryMessages.push({application, message: clone(message)});
                    return Promise.resolve(recoveryNative
                        ? recoveryNative(message)
                        : {id: message.id, requests: [], nextCursor: null});
                }
                nativeMessages.push({application, message: clone(message)});
                return Promise.resolve(message.subject === "acknowledgeResponse"
                    ? acknowledgeResponse(message)
                    : native?.(message));
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
                    return storageSet
                        ? Promise.resolve(storageSet(clone(values)))
                        : Promise.resolve();
                },
                remove(key) {
                    storageRemovals.push(key);
                    storage.delete(key);
                    return Promise.resolve();
                },
            },
        },
        action: {
            onClicked: {addListener(value) { toolbarListener = value; }},
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
    const HarnessDate = dateNow ? class extends Date {
        constructor(...values) {
            super(values.length > 0 ? values[0] : dateNow());
        }
        static now() { return dateNow(); }
    } : Date;
    const context = vm.createContext({
        browser,
        crypto: webcrypto,
        console,
        Date: HarnessDate,
        importScripts(name) {
            assert.equal(name, "bridge_wire.js");
            new vm.Script(wireSource).runInContext(context);
        },
        Map,
        Object,
        Promise,
        Set,
        URL,
        clearTimeout(id) {
            timers.delete(id);
            cancelTimeout?.(id);
        },
        setTimeout(callback, delay) {
            timerDelays.push(delay);
            if (scheduleTimeout) { return scheduleTimeout(callback, delay); }
            const id = timerDelays.length;
            timers.set(id, {callback, delay});
            return id;
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
        alarms,
        alarmGets,
        alarmClears,
        alarmCreates,
        badgeTexts,
        nativeMessages,
        recoveryMessages,
        popupCalls,
        runtimeMessages,
        storage,
        storageRemovals,
        storageWrites,
        tabMessages,
        tabQueries() { return tabQueries; },
        timerDelays,
        read(expression) {
            return vm.runInContext(expression, context);
        },
        install(details) {
            return installedListener(details);
        },
        clickToolbar(tab) {
            toolbarListener(tab);
        },
        fireAlarm(name = recoveryAlarmName) {
            return alarmListener?.({name});
        },
        async runTimer(delay = 1000) {
            const entry = [...timers].find(([, value]) => value.delay === delay);
            if (!entry) { return false; }
            const [id, timer] = entry;
            timers.delete(id);
            await timer.callback();
            await settle();
            return true;
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
    await new Promise(setImmediate);
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

function manualSwitchIntent(overrides = {}) {
    return {
        subject: "manualSwitchIntent",
        host: "wallet.example",
        configurationKey: "https://wallet.example",
        workflowVersion: 3,
        ...overrides,
    };
}

function recoveryDescriptor(overrides = {}) {
    return {
        id: 31,
        host: "wallet.example",
        configurationKey: "https://wallet.example",
        requestToken,
        revisions: {ethereum: 0, solana: 0},
        state: "pending",
        ...overrides,
    };
}

function contentSender(tab = {}) {
    return {
        url: tab.url || "https://wallet.example/dapp",
        tab: {
            id: 9,
            url: "https://wallet.example/dapp",
            favIconUrl: "https://wallet.example/icon.png",
            incognito: false,
            ...tab,
        },
    };
}

function approvalProxy(id = 7, overrides = {}) {
    return {
        subject: "approveRequestWithCurrentRevisions",
        id,
        host: "wallet.example",
        configurationKey: "https://wallet.example",
        requestToken,
        reviewToken,
        payload: {},
        privateBrowsing: false,
        workflowVersion: 3,
        ...overrides,
    };
}

function popupSender(overrides = {}) {
    return {
        id: "extension-id",
        url: "safari-web-extension://extension-id/popup.html",
        ...overrides,
    };
}

function nativeAcknowledgement(
    id,
    revisions = {ethereum: 0, solana: 0},
    approvalRequired = true
) {
    return {id, requestToken, approvalRequired, revisions};
}

function completedAccountFixture(id = 23) {
    const configuration = {
        provider: "ethereum",
        chainId: "0x1",
        results: ["0x0000000000000000000000000000000000000001"],
    };
    const read = {
        subject: "getResponse",
        id,
        configurationKey: "https://wallet.example",
        requestToken,
        revisions: {ethereum: 0, solana: 0},
        workflowVersion: 3,
    };
    return {
        configuration,
        read,
        apply: {...read, subject: "applyCompletedResponse", host: "wallet.example"},
        response: {
            id,
            name: "requestAccounts",
            ...configuration,
            configurationToStore: configuration,
        },
    };
}

function completedResponseStore(count) {
    const records = new Map;
    const pageSizes = [];
    for (let id = 1; id <= count; id += 1) {
        const fixture = completedAccountFixture(id);
        fixture.read.requestToken = `00000000-0000-4000-8000-${String(id).padStart(12, "0")}`;
        records.set(id, {
            read: fixture.read,
            identity: {
                id,
                host: "wallet.example",
                configurationKey: fixture.read.configurationKey,
                requestToken: fixture.read.requestToken,
                revisions: fixture.read.revisions,
            },
            response: {...fixture.response, __bwApprovalCommitted: true},
            acknowledged: false,
        });
    }
    function matching(message) {
        const record = records.get(message.id);
        assert.equal(message.configurationKey, record.identity.configurationKey);
        assert.equal(message.requestToken, record.identity.requestToken);
        return record;
    }
    return {
        records,
        pageSizes,
        native(message) {
            if (message.subject === "getPendingRequests") {
                const completedResponses = [...records.values()]
                    .filter(record => !record.acknowledged)
                    .slice(0, 16).map(record => record.identity);
                pageSizes.push(completedResponses.length);
                return clone({requests: [], completedResponses});
            }
            assert.equal(message.subject, "getResponse");
            return clone(matching(message).response);
        },
        acknowledge(message) {
            matching(message).acknowledged = true;
            return {id: message.id, acknowledged: true};
        },
    };
}

function openRecoveryPopup(worker, native) {
    const elements = new Map;
    const listeners = new Map;
    let open = true;
    const document = {
        documentElement: popupElement("document-element"),
        addEventListener(name, listener) { listeners.set(name, listener); },
        createElement: () => popupElement("created"),
        getElementById(id) {
            if (!elements.has(id)) { elements.set(id, popupElement(id)); }
            return elements.get(id);
        },
        querySelectorAll: () => [],
    };
    const unavailable = () => new Promise(() => {});
    const context = vm.createContext({
        URL,
        crypto: webcrypto,
        document,
        navigator: {maxTouchPoints: 5},
        setTimeout: () => 1,
        clearTimeout() {},
        window: {close() { open = false; }},
        browser: {
            extension: {inIncognitoContext: false},
            runtime: {
                getManifest: () => ({version: packagedMarketingVersion}),
                onMessage: {addListener() {}},
                sendMessage(message) {
                    if (!open) { return unavailable(); }
                    return worker.dispatch(clone(message), popupSender()).then(value =>
                        open ? clone(value) : unavailable()
                    );
                },
                sendNativeMessage(_application, message) {
                    return open ? Promise.resolve(native(clone(message))) : unavailable();
                },
            },
            storage: {local: {get: async key => ({[key]: worker.storage.get(key)})}},
            tabs: {query: async () => [contentSender().tab]},
        },
    });
    new vm.Script(wireSource).runInContext(context);
    new vm.Script(popupSource, {filename: "popup.js"}).runInContext(context);
    listeners.get("DOMContentLoaded")();
    return {
        element: id => document.getElementById(id),
        close() { open = false; },
        refresh: () => vm.runInContext("refreshIdleStatus()", context),
        async waitForIdleText(text) {
            for (let attempt = 0; attempt < 50; attempt += 1) {
                await settle();
                if (document.getElementById("idle-connection").textContent === text) {
                    return;
                }
            }
            assert.equal(document.getElementById("idle-connection").textContent, text);
        },
    };
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

test("macOS popup cues stay hidden without a configured extension popup", async () => {
    const harness = makeHarness({
        configuredPopup: false,
        native: () => nativeAcknowledgement(7),
    });
    assert.equal((await harness.dispatch(request())).requestToken, requestToken);
    await settle();
    assert.ok(harness.badgeTexts.length >= 1);
    assert.ok(harness.badgeTexts.every(value => value === ""));
    assert.deepEqual(harness.popupCalls, []);
    assert.deepEqual(harness.runtimeMessages, [{
        subject: "pendingRequestAvailable",
        workflowVersion: 3,
    }]);
    await harness.dispatch({
        subject: "updatePendingRequestBadge",
        hasPendingRequests: true,
        workflowVersion: 3,
    }, {});
    assert.ok(harness.badgeTexts.every(value => value === ""));
    harness.install({reason: "update"});
    harness.startup();
    await settle();
    assert.ok(harness.badgeTexts.every(value => value === ""));
});

test("toolbar requests a switch and preserves native fallback", async () => {
    const response = {
        approvalRequired: false,
        configurationKey: "https://wallet.example",
        id: 31,
        requestToken,
        revisions: {ethereum: 0, solana: 0},
        subject: "manualSwitchAcknowledged",
        workflowVersion: 3,
    };
    const harness = makeHarness({
        configuredPopup: false,
        native: () => ({opened: true}),
        sendTabMessage: (_id, message) => message.subject === "workflowProbe"
            ? {
                buildVersion: packagedBuildVersion,
                nonce: message.nonce,
                subject: "workflowProbe",
                workflowVersion: 3,
            }
            : response,
    });
    harness.clickToolbar({
        id: 9,
        url: "https://wallet.example/dapp",
        incognito: false,
    });
    await settle();

    assert.deepEqual(harness.tabMessages.at(-1), {
        id: 9,
        message: {
            configurationKey: "https://wallet.example",
            subject: "manualSwitchIntent",
            workflowVersion: 3,
        },
    });
    assert.equal(harness.nativeMessages.length, 0);
    assert.equal(harness.timerDelays.includes(10_000), true);

    harness.clickToolbar({id: 10, url: "safari://blank", incognito: false});
    await settle();
    assert.equal(harness.nativeMessages.at(-1).message.subject, "openApp");

    const unavailable = makeHarness({
        configuredPopup: false,
        native: () => ({opened: true}),
        sendTabMessage: (_id, message) => message.subject === "workflowProbe"
            ? {
                buildVersion: packagedBuildVersion,
                nonce: message.nonce,
                subject: "workflowProbe",
                workflowVersion: 3,
            }
            : undefined,
    });
    unavailable.clickToolbar({
        id: 11,
        url: "https://wallet.example/dapp",
        incognito: false,
    });
    await settle();
    assert.equal(unavailable.nativeMessages.at(-1).message.subject, "openApp");

    const stale = makeHarness({
        configuredPopup: false,
        native: () => ({opened: true}),
        sendTabMessage: (_id, message) => ({
            buildVersion: previousBuildVersion,
            nonce: message.nonce,
            subject: "workflowProbe",
            workflowVersion: 3,
        }),
    });
    stale.clickToolbar({
        id: 12,
        url: "https://wallet.example/dapp",
        incognito: false,
    });
    await settle();
    assert.equal(stale.nativeMessages.at(-1).message.subject, "openApp");
});

test("toolbar restores the same approval while background polling stays silent", async () => {
    const polling = deferred();
    const harness = makeHarness({
        configuredPopup: false,
        native: message => {
            if (isResponseRead(message)) { return polling.promise; }
            if (message.subject === "showApproval") { return {opened: true}; }
            return nativeAcknowledgement(message.id, message.revisions);
        },
        sendTabMessage: (_id, message) => message.subject === "workflowProbe"
            ? {
                buildVersion: packagedBuildVersion,
                nonce: message.nonce,
                subject: "workflowProbe",
                workflowVersion: 3,
            }
            : harness.dispatch(manualSwitchIntent(), contentSender()),
    });
    const acknowledged = await harness.dispatch(manualSwitchIntent(), contentSender());
    const backgroundPoll = harness.runTimer();
    await settle();
    assert.equal(harness.nativeMessages.some(({message}) =>
        isResponseRead(message)
    ), true);
    assert.equal(harness.nativeMessages.some(({message}) =>
        message.subject === "showApproval"
    ), false);

    const tab = {id: 9, url: "https://wallet.example/dapp", incognito: false};
    for (let click = 0; click < 2; click += 1) {
        harness.clickToolbar(tab);
        await settle();
    }
    const activations = harness.nativeMessages.filter(({message}) =>
        message.subject === "showApproval"
    );
    assert.equal(activations.length, 2);
    assert.deepEqual(activations.map(({message}) => message), Array(2).fill({
        __bwPrivateBrowsing: false,
        subject: "showApproval",
        id: acknowledged.id,
        configurationKey: "https://wallet.example",
        requestToken,
        workflowVersion: 3,
    }));
    assert.equal(harness.nativeMessages.filter(({message}) =>
        message.name === "switchAccount"
    ).length, 1);
    polling.resolve(undefined);
    await backgroundPoll;
});

test("toolbar probe failures always open the native wallet", async () => {
    const tab = {id: 13, url: "https://wallet.example/dapp", incognito: false};
    const malformedResponses = [undefined, {}, {
        buildVersion: packagedBuildVersion,
        nonce: "invalid",
        subject: "workflowProbe",
        workflowVersion: 3,
    }];
    for (const probe of malformedResponses) {
        const harness = makeHarness({
            configuredPopup: false,
            native: () => ({opened: true}),
            sendTabMessage: () => probe,
        });
        harness.clickToolbar(tab);
        await settle();
        assert.equal(harness.nativeMessages.at(-1).message.subject, "openApp");
    }

    const timedOut = makeHarness({
        configuredPopup: false,
        native: () => ({opened: true}),
        scheduleTimeout(callback, delay) {
            if (delay === 1000) { queueMicrotask(callback); }
            return delay;
        },
        sendTabMessage: () => new Promise(() => {}),
    });
    timedOut.clickToolbar(tab);
    await settle();
    assert.equal(timedOut.nativeMessages.at(-1).message.subject, "openApp");

    for (const failIntent of [false, true]) {
        const rejected = makeHarness({
            configuredPopup: false,
            native: () => ({opened: true}),
            sendTabMessage: (_id, message) => {
                if (failIntent && message.subject === "workflowProbe") {
                    return {
                        buildVersion: packagedBuildVersion,
                        nonce: message.nonce,
                        subject: "workflowProbe",
                        workflowVersion: 3,
                    };
                }
                throw new Error("Unexpected tab messaging failure");
            },
        });
        rejected.clickToolbar(tab);
        await settle();
        assert.equal(rejected.nativeMessages.at(-1).message.subject, "openApp");
    }
});

test("a stalled toolbar manual-switch relay falls back after ten seconds", async () => {
    const harness = makeHarness({
        configuredPopup: false,
        native: () => ({opened: true}),
        scheduleTimeout(callback, delay) {
            if (delay === 10_000) { queueMicrotask(callback); }
            return delay;
        },
        sendTabMessage: (_id, message) => message.subject === "workflowProbe"
            ? {
                buildVersion: packagedBuildVersion,
                nonce: message.nonce,
                subject: "workflowProbe",
                workflowVersion: 3,
            }
            : new Promise(() => {}),
    });
    harness.clickToolbar({
        id: 14,
        url: "https://wallet.example/dapp",
        incognito: false,
    });
    await settle();

    assert.equal(harness.timerDelays.includes(10_000), true);
    assert.equal(harness.nativeMessages.at(-1).message.subject, "openApp");
});

test("simultaneous manual clicks share one admission and accept its canonical native handle", async () => {
    const admission = deferred();
    const harness = makeHarness({native: () => admission.promise});
    const first = harness.dispatch(manualSwitchIntent(), contentSender());
    const second = harness.dispatch(manualSwitchIntent(), contentSender({id: 10}));
    await settle();
    assert.equal(harness.nativeMessages.length, 1);
    assert.equal(harness.storageWrites.length, 0);
    const nativeRequest = harness.nativeMessages[0].message;
    assert.equal(nativeRequest.name, "switchAccount");
    assert.deepEqual(nativeRequest.body, {latestConfigurations: []});
    assert.match(nativeRequest.enqueueAttempt, /^[0-9a-f]{32}$/);
    const canonicalId = nativeRequest.id === 31 ? 32 : 31;
    admission.resolve(nativeAcknowledgement(canonicalId, {ethereum: 4, solana: 6}));
    const responses = await Promise.all([first, second]);
    assert.deepEqual(clone(responses[0]), clone(responses[1]));
    assert.equal(responses[0].id, canonicalId);
    assert.deepEqual(clone(responses[0].revisions), {ethereum: 4, solana: 6});
});

test("manual admission omits oversized favicons and preserves ordinary favicon URLs", async () => {
    for (const favicon of [
        "https://wallet.example/icon.png",
        "data:image/png;base64," + "A".repeat(300_000),
        "data:image/svg+xml," + "\u{1F600}".repeat(80_000),
    ]) {
        const harness = makeHarness({native: message => {
            assert.ok(Buffer.byteLength(JSON.stringify(message)) <= 256 * 1024);
            return nativeAcknowledgement(message.id, message.revisions);
        }});

        const response = await harness.dispatch(
            manualSwitchIntent(), contentSender({favIconUrl: favicon})
        );

        assert.equal(response.subject, "manualSwitchAcknowledged");
        assert.equal(harness.nativeMessages[0].message.favicon,
            favicon.startsWith("https:") ? favicon : "");
    }
});

test("the first toolbar click after retention expiry starts fresh even before delayed timers run", async () => {
    let now = 1_700_000_000_000;
    const tab = {id: 9, url: "https://wallet.example/dapp", incognito: false};
    let harness;
    harness = makeHarness({
        configuredPopup: false,
        dateNow: () => now,
        native: message => message.name === "switchAccount"
            ? nativeAcknowledgement(message.id, message.revisions)
            : undefined,
        sendTabMessage: (_, message) => message.subject === "workflowProbe"
            ? {
                subject: "workflowProbe",
                nonce: message.nonce,
                workflowVersion: 3,
                buildVersion: packagedBuildVersion,
            }
            : harness.dispatch({...message, host: "wallet.example"}, contentSender(tab)),
    });
    harness.clickToolbar(tab);
    await settle();
    const first = harness.nativeMessages.find(({message}) => message.name === "switchAccount").message;
    now += 76 * 60 * 1000;

    harness.clickToolbar(tab);
    await settle();

    const admissions = harness.nativeMessages.filter(({message}) => message.name === "switchAccount");
    assert.equal(admissions.length, 2);
    assert.notEqual(admissions[1].message.id, first.id);
    const presentations = harness.nativeMessages.filter(({message}) => message.subject === "showApproval");
    assert.equal(presentations.length, 2);
    assert.equal(presentations[1].message.id, admissions[1].message.id);
});

test("a live macOS switch polls after one second and persists before notifying and acknowledging", async () => {
    const selected = {
        provider: "ethereum",
        chainId: "0x1",
        results: ["0x0000000000000000000000000000000000000001"],
    };
    const storage = new Map;
    const harness = makeHarness({
        configuredPopup: false,
        storage,
        tabs: [
            {id: 9, url: "https://wallet.example/dapp", incognito: false},
            {id: 10, url: "https://wallet.example/other", incognito: false},
            {id: 11, url: "https://other.example", incognito: false},
            {id: 12, url: "http://wallet.example", incognito: false},
            {id: 13, url: "https://wallet.example/private", incognito: true},
        ],
        native: message => isResponseRead(message) ? {
            id: message.id,
            name: "switchAccount",
            provider: "multiple",
            bodies: [selected],
            configurationToStore: [selected],
            providersToDisconnect: [],
        } : nativeAcknowledgement(message.id, message.revisions),
        acknowledgeResponse: message => {
            assert.equal(storage.get("https://wallet.example").revisions.ethereum, 1);
            assert.deepEqual(harness.tabMessages.filter(({message}) =>
                message.subject === "configurationChanged"
            ).map(({id}) => id), [9, 10]);
            return {id: message.id, acknowledged: true};
        },
    });
    const response = await harness.dispatch(manualSwitchIntent(), contentSender());
    assert.equal(response.subject, "manualSwitchAcknowledged");
    assert.equal(harness.nativeMessages.length, 1);
    assert.equal(await harness.runTimer(), true);
    assert.deepEqual(harness.popupCalls, []);
    assert.equal(harness.nativeMessages.filter(({message}) =>
        isResponseRead(message)
    ).length, 1);
    assert.equal(harness.nativeMessages.filter(({message}) =>
        message.subject === "acknowledgeResponse"
    ).length, 1);
    assert.equal(await harness.runTimer(), false);
    assert.deepEqual(harness.alarmCreates, [{
        name: recoveryAlarmName,
        options: {delayInMinutes: 1, periodInMinutes: 1},
    }]);
    assert.equal(harness.tabMessages.some(({message}) =>
        message.subject === "manualSwitchResult"
    ), false);
});

test("response-ready hints share a live switch read and retries do not repeat a committed change", async () => {
    let acknowledge = false;
    const read = deferred();
    const harness = makeHarness({
        tabs: [{id: 9, url: "https://wallet.example/dapp"}],
        native: message => isResponseRead(message)
            ? read.promise
            : nativeAcknowledgement(message.id, message.revisions),
        acknowledgeResponse: message => acknowledge
            ? {id: message.id, acknowledged: true}
            : undefined,
    });
    const admitted = await harness.dispatch(manualSwitchIntent(), contentSender());
    const hint = {subject: "responseReady", id: admitted.id, workflowVersion: 3};
    const first = harness.dispatch(hint, {});
    const second = harness.dispatch(hint, {});
    await settle();
    assert.equal(harness.nativeMessages.filter(({message}) =>
        isResponseRead(message)
    ).length, 1);
    read.resolve({
        id: admitted.id,
        name: "switchAccount",
        provider: "multiple",
        bodies: [],
        configurationToStore: [],
        providersToDisconnect: ["ethereum", "solana"],
    });
    await Promise.all([first, second]);
    const revisions = clone(harness.storage.get("https://wallet.example").revisions);
    const writes = providerStateWrites(harness).length;
    const notifications = harness.tabMessages.filter(({message}) =>
        message.subject === "configurationChanged"
    ).length;
    acknowledge = true;
    assert.equal(await harness.runTimer(), true);
    assert.deepEqual(harness.storage.get("https://wallet.example").revisions, revisions);
    assert.equal(providerStateWrites(harness).length, writes);
    assert.equal(harness.tabMessages.filter(({message}) =>
        message.subject === "configurationChanged"
    ).length, notifications + 1);
    assert.equal(await harness.runTimer(), false);
});

test("popup and live switch completion share one native read and configuration commit", async () => {
    const read = deferred();
    const harness = makeHarness({
        native: message => isResponseRead(message)
            ? read.promise
            : nativeAcknowledgement(message.id, message.revisions),
    });
    const admitted = await harness.dispatch(manualSwitchIntent(), contentSender());
    const live = harness.dispatch({
        subject: "responseReady",
        id: admitted.id,
        workflowVersion: 3,
    }, {});
    await settle();
    const popup = harness.dispatch({
        subject: "applyCompletedResponse",
        host: "wallet.example",
        configurationKey: "https://wallet.example",
        id: admitted.id,
        requestToken,
        revisions: clone(admitted.revisions),
        workflowVersion: 3,
    }, popupSender());
    await settle();
    assert.equal(harness.nativeMessages.filter(({message}) =>
        isResponseRead(message)
    ).length, 1);
    read.resolve({
        id: admitted.id,
        name: "switchAccount",
        provider: "multiple",
        bodies: [],
        configurationToStore: [],
        providersToDisconnect: ["ethereum", "solana"],
    });
    const [, response] = await Promise.all([live, popup]);
    assert.deepEqual(clone(response), {applied: true});
    assert.equal(providerStateWrites(harness).length, 1);
    assert.equal(harness.nativeMessages.filter(({message}) =>
        message.subject === "acknowledgeResponse"
    ).length, 1);
});

test("a missing live switch is forgotten and another click admits again", async () => {
    const harness = makeHarness({native: message => isResponseRead(message)
        ? {id: message.id, missing: true}
        : nativeAcknowledgement(message.id, message.revisions)});
    await harness.dispatch(manualSwitchIntent(), contentSender());
    await harness.runTimer();
    assert.equal(harness.nativeMessages.filter(({message}) =>
        message.name === "switchAccount"
    ).length, 1);
    await harness.dispatch(manualSwitchIntent(), contentSender());
    assert.equal(harness.nativeMessages.filter(({message}) =>
        message.name === "switchAccount"
    ).length, 2);
});

test("clicking a switch whose native response expired retries admission once", async () => {
    for (const sharesBackgroundRead of [false, true]) {
        let now = 1_700_000_000_000;
        const read = deferred();
        const harness = makeHarness({
            dateNow: () => now,
            native: message => isResponseRead(message)
                ? read.promise
                : nativeAcknowledgement(message.id, message.revisions),
        });
        const first = await harness.dispatch(manualSwitchIntent(), contentSender());
        now += 61 * 60 * 1000;
        if (sharesBackgroundRead) { await harness.runTimer(); }

        await Promise.all([
            harness.dispatch(manualSwitchIntent(), contentSender()),
            harness.dispatch(manualSwitchIntent(), contentSender({id: 10})),
        ]);
        await settle();
        assert.equal(harness.nativeMessages.filter(({message}) =>
            isResponseRead(message)
        ).length, 1);
        read.resolve({id: first.id, missing: true});
        await settle();

        const admissions = harness.nativeMessages.filter(({message}) =>
            message.name === "switchAccount"
        );
        assert.equal(admissions.length, 2);
        assert.notEqual(admissions[1].message.id, first.id);
    }
});

test("a click does not readmit a completed switch or a failed native read", async () => {
    for (const completes of [false, true]) {
        const harness = makeHarness({native: message => {
            if (message.name === "switchAccount") {
                return nativeAcknowledgement(message.id, message.revisions);
            }
            return completes ? {
                id: message.id,
                name: "switchAccount",
                provider: "unknown",
                error: "Canceled",
                errorCode: 4001,
            } : undefined;
        }});
        await harness.dispatch(manualSwitchIntent(), contentSender());

        await harness.dispatch(manualSwitchIntent(), contentSender());
        await settle();

        assert.equal(harness.nativeMessages.filter(({message}) =>
            message.name === "switchAccount"
        ).length, 1);
    }
});

test("a lost switch admission reply requires another click and resumes the canonical native request", async () => {
    const storage = new Map;
    let original;
    const native = message => {
        if (message.name !== "switchAccount") { return undefined; }
        if (!original) {
            original = clone(message);
            return undefined;
        }
        return nativeAcknowledgement(original.id, original.revisions);
    };
    const first = makeHarness({storage, native});
    assert.equal(await first.dispatch(manualSwitchIntent(), contentSender()), undefined);
    const restarted = makeHarness({storage, native});
    restarted.startup();
    await settle();
    assert.equal(restarted.nativeMessages.length, 0);
    assert.equal(await restarted.runTimer(), false);
    assert.equal(await restarted.fireAlarm(), undefined);
    const resumed = await restarted.dispatch(manualSwitchIntent(), contentSender());
    assert.equal(resumed.id, original.id);
    assert.equal(resumed.requestToken, requestToken);
    assert.notEqual(restarted.nativeMessages[0].message.enqueueAttempt, original.enqueueAttempt);
});

test("another click recovers an unacknowledged completed switch before a later click starts a new one", async () => {
    let acknowledged = false;
    const native = message => {
        if (message.name === "switchAccount") {
            return {...nativeAcknowledgement(acknowledged ? 32 : 31), approvalRequired: false};
        }
        if (isResponseRead(message)) {
            return {
                id: message.id,
                name: "switchAccount",
                provider: "unknown",
                error: "Canceled",
                errorCode: 4001,
            };
        }
    };
    const harness = makeHarness({
        native,
        acknowledgeResponse: message => {
            acknowledged = true;
            return {id: message.id, acknowledged: true};
        },
    });
    await settle();
    assert.equal(harness.nativeMessages.length, 0);
    const recovered = await harness.dispatch(manualSwitchIntent(), contentSender());
    assert.equal(recovered.id, 31);
    await harness.runTimer();
    assert.equal(acknowledged, true);
    const next = await harness.dispatch(manualSwitchIntent(), contentSender());
    assert.equal(next.id, 32);
});

test("a failed switch configuration write is retried before acknowledgement", async () => {
    let failWrite = true;
    const harness = makeHarness({
        storageSet: values => {
            if (failWrite && values["https://wallet.example"]) {
                throw new Error("storage unavailable");
            }
        },
        native: message => isResponseRead(message) ? {
            id: message.id,
            name: "switchAccount",
            provider: "multiple",
            bodies: [],
            configurationToStore: [],
            providersToDisconnect: ["ethereum", "solana"],
        } : nativeAcknowledgement(message.id, message.revisions),
    });
    await harness.dispatch(manualSwitchIntent(), contentSender());
    await harness.runTimer();
    assert.equal(harness.nativeMessages.some(({message}) =>
        message.subject === "acknowledgeResponse"
    ), false);
    failWrite = false;
    await harness.runTimer();
    assert.equal(harness.nativeMessages.filter(({message}) =>
        message.subject === "acknowledgeResponse"
    ).length, 1);
});

test("a switch completed before admission expiry survives a delayed completion hint", async () => {
    let now = 1_700_000_000_000;
    let terminal;
    const selected = {
        provider: "ethereum",
        chainId: "0x1",
        results: ["0x0000000000000000000000000000000000000001"],
    };
    const harness = makeHarness({
        dateNow: () => now,
        tabs: [{id: 9, url: "https://wallet.example/dapp"}],
        native: message => isResponseRead(message)
            ? terminal
            : nativeAcknowledgement(message.id, message.revisions),
    });
    const admitted = await harness.dispatch(manualSwitchIntent(), contentSender());
    const admissionDeadline = harness.nativeMessages[0].message.admissionDeadline;
    assert.equal(admissionDeadline, now + 15 * 60 * 1000);
    now = admissionDeadline - 1;
    terminal = {
        id: admitted.id,
        name: "switchAccount",
        provider: "multiple",
        bodies: [selected],
        configurationToStore: [selected],
        providersToDisconnect: [],
    };
    now = admissionDeadline + 1;
    await harness.dispatch({
        subject: "responseReady",
        id: admitted.id,
        workflowVersion: 3,
    }, {});

    assert.deepEqual(harness.storage.get("https://wallet.example"), {
        latestConfigurations: [{...selected, reauthorizationRevision: 1}],
        revisions: {ethereum: 1, solana: 0},
        workflowVersion: 3,
    });
    assert.equal(harness.nativeMessages.filter(({message}) =>
        isResponseRead(message)
    ).length, 1);
    assert.equal(harness.nativeMessages.filter(({message}) =>
        message.subject === "acknowledgeResponse"
    ).length, 1);
    assert.equal(harness.tabMessages.filter(({message}) =>
        message.subject === "configurationChanged"
    ).length, 1);
    assert.equal(await harness.runTimer(), false);
});

test("manual polling rejects malformed switch terminals and stops after response retention", async () => {
    let now = 1_700_000_000_000;
    const harness = makeHarness({
        dateNow: () => now,
        native: message => isResponseRead(message) ? {
            id: message.id,
            name: "switchAccount",
            provider: "ethereum",
            results: ["0x0000000000000000000000000000000000000001"],
            configurationToStore: {
                provider: "ethereum",
                chainId: "0x1",
                results: ["0x0000000000000000000000000000000000000001"],
            },
        } : nativeAcknowledgement(message.id, message.revisions),
    });
    await harness.dispatch(manualSwitchIntent(), contentSender());
    await harness.runTimer();
    assert.equal(providerStateWrites(harness).length, 0);
    assert.equal(harness.nativeMessages.some(({message}) =>
        message.subject === "acknowledgeResponse"
    ), false);
    now += (15 + 60) * 60 * 1000;
    const count = harness.nativeMessages.length;
    await harness.runTimer();
    assert.equal(harness.nativeMessages.length, count);
    assert.equal(await harness.runTimer(), false);
    await harness.dispatch(manualSwitchIntent(), contentSender());
    assert.equal(harness.nativeMessages.filter(({message}) =>
        message.name === "switchAccount"
    ).length, 2);
});

test("startup discovers native work without admitting or changing unrelated storage", async () => {
    const storage = new Map([["unrelated", true]]);
    const harness = makeHarness({storage, native: () => assert.fail("no automatic recovery")});
    harness.startup();
    await settle();
    assert.equal(storage.get("unrelated"), true);
    assert.deepEqual(harness.alarmCreates, [{
        name: recoveryAlarmName,
        options: {delayInMinutes: 1, periodInMinutes: 1},
    }]);
    assert.deepEqual(harness.alarmClears, []);
    assert.deepEqual(harness.storageRemovals, ["workflowUpdateRecoveryNeeded"]);
    assert.equal(harness.recoveryMessages.length, 1);
    assert.equal(await harness.fireAlarm(), undefined);
    assert.equal(await harness.runTimer(), false);
    assert.equal(harness.nativeMessages.length, 0);
});

test("an alarm recovers an approval after worker termination before its admission reply", async () => {
    const alarms = new Map;
    const storage = new Map;
    const lostReply = deferred();
    let descriptor;
    const discovery = message => ({id: message.id, requests: descriptor ? [descriptor] : [], nextCursor: null});
    const first = makeHarness({
        alarms, storage, recoveryNative: discovery,
        native: message => {
            assert.equal(alarms.has(recoveryAlarmName), true);
            descriptor = recoveryDescriptor({id: message.id});
            return lostReply.promise;
        },
    });
    void first.dispatch(manualSwitchIntent(), contentSender());
    await settle();
    assert.equal(first.nativeMessages.length, 1);
    const second = makeHarness({
        alarms, storage, recoveryNative: discovery,
        tabs: [{id: 9, url: "https://wallet.example/dapp"}],
        native: message => {
            assert.equal(message.subject, "getManualSwitchResponse");
            assert.equal(message.id, descriptor.id);
            return {
                id: message.id, name: "switchAccount", provider: "multiple",
                bodies: [{provider: "ethereum", chainId: "0x1", results: ["0x0000000000000000000000000000000000000001"]}],
                configurationToStore: [{provider: "ethereum", chainId: "0x1", results: ["0x0000000000000000000000000000000000000001"]}],
                providersToDisconnect: [],
            };
        },
        acknowledgeResponse: message => {
            assert.equal(storage.get("https://wallet.example").revisions.ethereum, 1);
            descriptor = null;
            return {id: message.id, acknowledged: true};
        },
    });
    await settle();
    assert.equal(second.nativeMessages.length, 0);
    assert.equal(second.alarmCreates.length, 0);
    assert.equal(await second.runTimer(), false);
    descriptor.state = "approved";

    await second.fireAlarm();

    assert.deepEqual(second.nativeMessages.map(({message}) => message.subject), [
        "getManualSwitchResponse", "acknowledgeResponse",
    ]);
    assert.equal(second.tabMessages.filter(({message}) => message.subject === "configurationChanged").length, 1);
    assert.equal(await second.runTimer(), false);
    await second.fireAlarm();
    assert.equal(alarms.has(recoveryAlarmName), true);
});

test("recovery rebroadcasts the current stored configuration before acknowledging an already committed switch", async () => {
    const approved = {
        provider: "ethereum",
        chainId: "0x1",
        results: ["0x0000000000000000000000000000000000000001"],
    };
    for (const revision of [1, 3]) {
        const current = {
            ...approved,
            results: [revision === 1 ? approved.results[0] : "0x0000000000000000000000000000000000000002"],
            reauthorizationRevision: revision,
        };
        const stored = {
            latestConfigurations: [current],
            revisions: {ethereum: revision, solana: 0},
            workflowVersion: 3,
        };
        const storage = new Map([["https://wallet.example", stored]]);
        const descriptor = recoveryDescriptor({state: "completed"});
        let acknowledged = false;
        const harness = makeHarness({
            storage,
            tabs: [
                {id: 9, url: "https://wallet.example/dapp", incognito: false, active: true},
                {id: 10, url: "https://other.example", incognito: false},
                {id: 11, url: "https://wallet.example/private", incognito: true},
            ],
            recoveryNative: message => ({id: message.id, requests: acknowledged ? [] : [descriptor], nextCursor: null}),
            native: message => ({
                id: message.id,
                name: "switchAccount",
                provider: "multiple",
                bodies: [approved],
                configurationToStore: [approved],
                providersToDisconnect: [],
                __bwApprovalCommitted: true,
            }),
            acknowledgeResponse: message => {
                assert.deepEqual(harness.tabMessages, [{id: 9, message: {
                    subject: "configurationChanged",
                    configurationKey: "https://wallet.example",
                    latestConfigurations: [{...current, accountRevision: revision}],
                    revisions: stored.revisions,
                    workflowVersion: 3,
                }}]);
                acknowledged = true;
                return {id: message.id, acknowledged: true};
            },
        });

        await settle();

        assert.equal(acknowledged, true);
        assert.equal(providerStateWrites(harness).length, 0);
        assert.deepEqual(storage.get("https://wallet.example"), stored);
    }
});

test("recovery retries unacknowledged completions without a duplicate configuration commit", async () => {
    let acknowledged = false;
    let allowAcknowledgement = false;
    const descriptor = recoveryDescriptor({state: "completed"});
    const harness = makeHarness({
        recoveryNative: message => ({id: message.id, requests: acknowledged ? [] : [descriptor], nextCursor: null}),
        native: message => {
            assert.equal(message.subject, "getManualSwitchResponse");
            return {
                id: message.id, name: "switchAccount", provider: "multiple",
                bodies: [], configurationToStore: [], providersToDisconnect: ["ethereum", "solana"],
            };
        },
        acknowledgeResponse: message => {
            acknowledged = allowAcknowledgement;
            return {id: message.id, acknowledged};
        },
    });
    await settle();
    const state = clone(harness.storage.get("https://wallet.example"));
    assert.equal(providerStateWrites(harness).length, 1);
    assert.equal(harness.alarms.has(recoveryAlarmName), true);
    allowAcknowledgement = true;
    await harness.fireAlarm();
    assert.deepEqual(harness.storage.get("https://wallet.example"), state);
    assert.equal(providerStateWrites(harness).length, 1);
    assert.equal(acknowledged, true);
    assert.equal(harness.nativeMessages.some(({message}) => message.name === "switchAccount" || message.subject === "getResponse"), false);
});

test("pending discovery and unavailable approved helpers never reopen native UI or fast poll", async () => {
    const descriptor = recoveryDescriptor();
    const harness = makeHarness({
        recoveryNative: message => ({id: message.id, requests: [descriptor], nextCursor: null}),
        native: message => {
            assert.equal(message.subject, "getManualSwitchResponse");
            return {id: message.id, pending: true};
        },
    });
    await settle();
    await harness.fireAlarm();
    assert.equal(harness.nativeMessages.length, 0);
    assert.equal(await harness.runTimer(), false);
    descriptor.state = "approved";
    await harness.fireAlarm();
    assert.equal(harness.nativeMessages.length, 1);
    assert.equal(await harness.runTimer(), false);
    await harness.fireAlarm();
    assert.equal(harness.nativeMessages.length, 2);
    assert.equal(harness.alarmCreates.length, 1);
    assert.equal(harness.alarms.has(recoveryAlarmName), true);
});

test("page configuration reads and response hints discover approved work without a new click", async () => {
    for (const trigger of ["configuration", "hint"]) {
        const descriptor = recoveryDescriptor();
        const harness = makeHarness({
            recoveryNative: message => ({id: message.id, requests: [descriptor], nextCursor: null}),
            native: message => {
                assert.equal(message.subject, "getManualSwitchResponse");
                return {id: message.id, name: "switchAccount", provider: "unknown", error: "Canceled", errorCode: 4001};
            },
        });
        await settle();
        assert.equal(harness.nativeMessages.length, 0);
        descriptor.state = "approved";
        await harness.dispatch(trigger === "hint"
            ? {subject: "responseReady", id: descriptor.id, workflowVersion: 3}
            : {subject: "getLatestConfiguration", host: descriptor.host, configurationKey: descriptor.configurationKey, workflowVersion: 3});
        await settle();
        assert.equal(harness.recoveryMessages.length, 2);
        assert.deepEqual(harness.nativeMessages.map(({message}) => message.subject), ["getManualSwitchResponse", "acknowledgeResponse"]);
    }
});

test("simultaneous wake triggers share one discovery and one quiet response read", async () => {
    const discovery = deferred();
    let discoveryID;
    const descriptor = recoveryDescriptor({state: "approved"});
    const harness = makeHarness({
        recoveryNative: message => { discoveryID = message.id; return discovery.promise; },
        native: message => {
            assert.equal(message.subject, "getManualSwitchResponse");
            return {id: message.id, pending: true};
        },
    });
    await settle();
    const alarm = harness.fireAlarm();
    const hint = harness.dispatch({subject: "responseReady", id: descriptor.id, workflowVersion: 3});
    const configuration = harness.dispatch({subject: "getLatestConfiguration", host: descriptor.host, configurationKey: descriptor.configurationKey, workflowVersion: 3});
    discovery.resolve({id: discoveryID, requests: [descriptor], nextCursor: null});
    await Promise.all([alarm, hint, configuration]);
    assert.equal(harness.recoveryMessages.length, 1);
    assert.equal(harness.nativeMessages.length, 1);
    assert.equal(await harness.runTimer(), false);
});

test("paginated discovery drains every same-origin handle without replacing its pending picker", async () => {
    const descriptors = Array.from({length: 17}, (_, index) => recoveryDescriptor({
        id: 200 + index,
        requestToken: `00000000-0000-4000-8000-${String(index).padStart(12, "0")}`,
        state: index === 0 ? "pending" : "completed",
    }));
    let outstanding = 0;
    let maximumOutstanding = 0;
    const harness = makeHarness({
        recoveryNative: message => ({
            id: message.id,
            requests: message.cursor ? descriptors.slice(16) : descriptors.slice(0, 16),
            nextCursor: message.cursor ? null : "next-page",
        }),
        native: async message => {
            assert.equal(message.subject, "getManualSwitchResponse");
            outstanding += 1;
            maximumOutstanding = Math.max(outstanding, maximumOutstanding);
            await settle();
            outstanding -= 1;
            return {id: message.id, name: "switchAccount", provider: "unknown", error: "Canceled", errorCode: 4001};
        },
    });
    await harness.fireAlarm();
    assert.deepEqual(harness.recoveryMessages.map(({message}) => message.cursor), [undefined, "next-page"]);
    assert.deepEqual(harness.nativeMessages.filter(({message}) => message.subject === "getManualSwitchResponse").map(({message}) => message.id), descriptors.slice(1).map(request => request.id));
    assert.equal(maximumOutstanding, 1);
    assert.equal(harness.nativeMessages.filter(({message}) => message.subject === "acknowledgeResponse").length, 16);
    assert.equal(await harness.runTimer(), false);
});

test("failed, malformed, and empty discovery all retain the recovery alarm", async () => {
    for (const failure of ["throw", "shape", "descriptor", "cursor"]) {
        let failing = true;
        const harness = makeHarness({
            recoveryNative: message => {
                if (!failing) { return {id: message.id, requests: [], nextCursor: null}; }
                if (failure === "throw") { throw new Error("native unavailable"); }
                if (failure === "shape") { return {id: message.id, requests: []}; }
                if (failure === "descriptor") { return {id: message.id, requests: [recoveryDescriptor({state: "unknown"})], nextCursor: null}; }
                return {id: message.id, requests: [], nextCursor: "same-cursor"};
            },
            native: () => assert.fail("Failed discovery must not read or admit requests"),
        });
        await settle();
        assert.equal(harness.alarms.has(recoveryAlarmName), true);
        failing = false;
        await harness.fireAlarm();
        assert.equal(harness.alarms.has(recoveryAlarmName), true);
    }
});

test("idle scans retain one alarm without resetting its scheduled wake", async () => {
    const alarm = {name: recoveryAlarmName, periodInMinutes: 1, scheduledTime: 1_800_000_000_000};
    const alarms = new Map([[recoveryAlarmName, alarm]]);
    const harness = makeHarness({alarms});
    await settle();
    harness.startup();
    await harness.fireAlarm();
    await harness.fireAlarm();
    assert.deepEqual(alarms.get(recoveryAlarmName), alarm);
    assert.equal(harness.alarmCreates.length, 0);
    assert.equal(harness.alarmClears.includes(recoveryAlarmName), false);
    assert.equal(harness.nativeMessages.length, 0);
    assert.ok(harness.recoveryMessages.length >= 3);
});

test("a native admission committed after the next worker's empty scan is recovered by its next alarm", async () => {
    const alarms = new Map;
    const storage = new Map;
    const abandonedReply = deferred();
    let descriptor;
    const discovery = message => ({id: message.id, requests: descriptor ? [descriptor] : [], nextCursor: null});
    const first = makeHarness({alarms, storage, recoveryNative: discovery, native: () => abandonedReply.promise});
    void first.dispatch(manualSwitchIntent(), contentSender());
    await settle();
    const admission = first.nativeMessages[0].message;
    const second = makeHarness({
        alarms, storage, recoveryNative: discovery,
        native: message => {
            assert.equal(message.subject, "getManualSwitchResponse");
            return {
                id: message.id, name: "switchAccount", provider: "multiple",
                bodies: [], configurationToStore: [], providersToDisconnect: ["ethereum", "solana"],
            };
        },
        acknowledgeResponse: message => {
            assert.deepEqual(storage.get("https://wallet.example").revisions, {ethereum: 1, solana: 1});
            descriptor = null;
            return {id: message.id, acknowledged: true};
        },
    });
    await settle();
    assert.equal(second.recoveryMessages.length, 1);
    assert.equal(second.nativeMessages.length, 0);
    assert.equal(alarms.has(recoveryAlarmName), true);
    descriptor = recoveryDescriptor({id: admission.id, state: "approved"});

    await second.fireAlarm();

    assert.deepEqual(second.nativeMessages.map(({message}) => message.subject), ["getManualSwitchResponse", "acknowledgeResponse"]);
    assert.equal(descriptor, null);
    assert.equal(second.alarmCreates.length, 0);
    assert.equal(alarms.has(recoveryAlarmName), true);
});

test("startup and admission share alarm creation before contacting native", async () => {
    const creation = deferred();
    const harness = makeHarness({
        createAlarm: () => creation.promise,
        native: message => {
            assert.equal(harness.alarms.has(recoveryAlarmName), true);
            return nativeAcknowledgement(message.id, message.revisions);
        },
    });
    const admitted = harness.dispatch(manualSwitchIntent(), contentSender());
    await settle();
    assert.equal(harness.nativeMessages.length, 0);
    assert.equal(harness.recoveryMessages.length, 0);
    assert.equal(harness.alarmCreates.length, 1);
    creation.resolve();
    assert.equal((await admitted).subject, "manualSwitchAcknowledged");
    assert.equal(harness.alarmCreates.length, 1);
});

test("failure to arm recovery prevents a new native admission", async () => {
    const harness = makeHarness({
        createAlarm: () => { throw new Error("alarm unavailable"); },
        native: () => assert.fail("Admission must wait for its recovery alarm"),
    });
    assert.equal(await harness.dispatch(manualSwitchIntent(), contentSender()), undefined);
    assert.equal(harness.recoveryMessages.length, 0);
    assert.equal(harness.nativeMessages.length, 0);
});

test("quiet recovery never joins or upgrades an interactive response read", async () => {
    const reading = deferred();
    let descriptor;
    const harness = makeHarness({
        recoveryNative: message => ({id: message.id, requests: descriptor ? [descriptor] : [], nextCursor: null}),
        native: message => {
            if (message.name === "switchAccount") {
                descriptor = recoveryDescriptor({id: message.id, state: "approved"});
                return nativeAcknowledgement(message.id, message.revisions);
            }
            assert.equal(message.subject, "getResponse");
            return reading.promise;
        },
    });
    const admitted = await harness.dispatch(manualSwitchIntent(), contentSender());
    await harness.runTimer();
    await harness.fireAlarm();
    assert.equal(harness.nativeMessages.filter(({message}) => isResponseRead(message)).length, 1);
    reading.resolve({id: admitted.id, name: "switchAccount", provider: "unknown", error: "Canceled", errorCode: 4001});
    await settle();
});

test("worker-private recovery stays silent and native discovery is not a page message API", async () => {
    const privateHarness = makeHarness({workerPrivateBrowsing: true, privateBrowsing: true});
    privateHarness.startup();
    await privateHarness.fireAlarm();
    await privateHarness.dispatch({subject: "getLatestConfiguration", host: "wallet.example", configurationKey: "https://wallet.example", workflowVersion: 3});
    assert.equal(privateHarness.recoveryMessages.length, 0);
    assert.equal(privateHarness.nativeMessages.length, 0);
    assert.equal(privateHarness.alarmCreates.length, 0);
    const harness = makeHarness();
    await settle();
    assert.equal(await harness.dispatch({id: 1, subject: "getManualSwitchRequests", workflowVersion: 3}), undefined);
    assert.equal(harness.recoveryMessages.length, 1);
});

test("manual reauthorization survives missed delivery, unrelated updates, and restart", async () => {
    const configurations = [
        {
            provider: "ethereum",
            chainId: "0x1",
            results: ["0x0000000000000000000000000000000000000001"],
        },
        {provider: "solana", publicKey: firstSolanaPublicKey},
    ];
    for (const selected of configurations) {
        const other = configurations.find(item => item.provider !== selected.provider);
        const revisions = {ethereum: 4, solana: 6};
        const storage = new Map([["https://wallet.example", {
            latestConfigurations: [selected],
            revisions,
            workflowVersion: 3,
        }]]);
        let terminal;
        const harness = makeHarness({
            storage,
            tabs: [{id: 9, url: "https://wallet.example/dapp", incognito: false}],
            sendTabMessage: () => Promise.reject(new Error("inactive document")),
            native: message => isResponseRead(message)
                ? terminal
                : nativeAcknowledgement(message.id, message.revisions),
        });
        const acknowledged = await harness.dispatch(manualSwitchIntent(), contentSender());
        terminal = {
            id: acknowledged.id,
            name: "switchAccount",
            provider: "multiple",
            bodies: [selected],
            providersToDisconnect: [],
            configurationToStore: [selected],
        };
        await harness.dispatch({
            subject: "responseReady",
            id: acknowledged.id,
            workflowVersion: 3,
        }, {});

        const reauthorizationRevision = revisions[selected.provider] + 1;
        assert.deepEqual(storage.get("https://wallet.example").latestConfigurations, [
            {...selected, reauthorizationRevision},
        ]);
        const manualResult = harness.tabMessages.find(value =>
            value.message.subject === "configurationChanged"
        ).message;
        assert.equal(manualResult.latestConfigurations[0].reauthorizationRevision,
            reauthorizationRevision);

        const afterManual = clone(storage.get("https://wallet.example").revisions);
        const replay = await harness.dispatch({
            subject: "getResponse",
            id: acknowledged.id,
            configurationKey: "https://wallet.example",
            requestToken,
            revisions,
            workflowVersion: 3,
        });
        assert.equal(replay.latestConfigurations[0].reauthorizationRevision,
            reauthorizationRevision);
        assert.deepEqual(storage.get("https://wallet.example").revisions, afterManual);

        terminal = {
            id: 71,
            name: other.provider === "ethereum" ? "requestAccounts" : "connect",
            ...other,
            configurationToStore: other,
        };
        await harness.dispatch({
            subject: "getResponse",
            id: terminal.id,
            configurationKey: "https://wallet.example",
            requestToken,
            revisions: afterManual,
            workflowVersion: 3,
        });
        const broadcast = harness.tabMessages.filter(value =>
            value.message.subject === "configurationChanged"
        ).at(-1).message;
        assert.equal(broadcast.latestConfigurations.find(item =>
            item.provider === selected.provider
        ).reauthorizationRevision, reauthorizationRevision);
        assert.equal(broadcast.latestConfigurations.find(item =>
            item.provider === other.provider
        ).reauthorizationRevision, undefined);

        const restarted = makeHarness({storage});
        const focused = await restarted.dispatch({
            subject: "getLatestConfiguration",
            host: "wallet.example",
            configurationKey: "https://wallet.example",
            workflowVersion: 3,
        });
        assert.equal(focused.latestConfigurations.find(item =>
            item.provider === selected.provider
        ).reauthorizationRevision, reauthorizationRevision);
        assert.deepEqual(clone(focused.revisions), broadcast.revisions);
        assert.equal(restarted.nativeMessages.length, 0);
    }
});

test("Ethereum chain changes preserve reauthorization until the account disconnects", async () => {
    const configuration = {
        provider: "ethereum",
        chainId: "0x1",
        results: ["0x0000000000000000000000000000000000000001"],
        reauthorizationRevision: 3,
    };
    const storage = new Map([["https://wallet.example", {
        latestConfigurations: [configuration],
        revisions: {ethereum: 3, solana: 0},
        workflowVersion: 3,
    }]]);
    const harness = makeHarness({storage, native: message => ({
        id: message.id,
        name: "switchEthereumChain",
        provider: "ethereum",
        chainId: "0x2",
        results: configuration.results,
        configurationToStore: {...configuration, chainId: "0x2", reauthorizationRevision: 99},
    })});
    const switched = await harness.dispatch(request(72, {message: {
        name: "switchEthereumChain",
        body: {address: configuration.results[0], chainId: "0x1", object: {chainId: "0x2"}},
    }}));
    assert.equal(switched.latestConfigurations[0].reauthorizationRevision, 3);
    assert.equal(switched.latestConfigurations[0].chainId, "0x2");
    assert.equal(switched.revisions.ethereum, 4);
    assert.deepEqual(storage.get("https://wallet.example").latestConfigurations, [
        {...configuration, chainId: "0x2"},
    ]);

    const disconnected = await harness.dispatch({
        subject: "disconnect",
        id: 73,
        provider: "ethereum",
        host: "wallet.example",
        configurationKey: "https://wallet.example",
        workflowVersion: 3,
    });
    assert.deepEqual(clone(disconnected.latestConfigurations), []);
    assert.deepEqual(storage.get("https://wallet.example").latestConfigurations, []);
    assert.equal(disconnected.revisions.ethereum, 5);
});

test("native configurations and manual replays cannot invent reauthorization", async () => {
    const configurations = [
        {
            provider: "ethereum",
            chainId: "0x1",
            results: ["0x0000000000000000000000000000000000000001"],
        },
        {provider: "solana", publicKey: firstSolanaPublicKey},
    ];
    for (const configuration of configurations) {
        let terminal = {
            id: 74,
            name: configuration.provider === "ethereum" ? "requestAccounts" : "connect",
            ...configuration,
            configurationToStore: {...configuration, reauthorizationRevision: 99},
        };
        const harness = makeHarness({native: () => terminal});
        const read = {
            subject: "getResponse",
            id: terminal.id,
            configurationKey: "https://wallet.example",
            requestToken,
            revisions: {ethereum: 0, solana: 0},
            workflowVersion: 3,
        };
        const connected = await harness.dispatch(read);
        assert.equal(connected.latestConfigurations[0].reauthorizationRevision, undefined);
        terminal = {
            id: read.id,
            name: "switchAccount",
            provider: "multiple",
            bodies: [configuration],
            configurationToStore: [{...configuration, reauthorizationRevision: 99}],
        };
        const replay = await harness.dispatch(read);
        assert.equal(replay, undefined);
        assert.deepEqual(harness.storage.get("https://wallet.example").latestConfigurations,
            [configuration]);
        assert.equal(harness.storage.get("https://wallet.example").revisions[
            configuration.provider
        ], 1);
    }
});

test("manual switch intent requires the exact trusted content identity", async () => {
    const harness = makeHarness({native: () => {
        assert.fail("untrusted manual intent must not reach native");
    }});
    for (const [message, sender] of [
        [{...manualSwitchIntent(), extra: true}, contentSender()],
        [manualSwitchIntent({host: "other.example"}), contentSender()],
        [manualSwitchIntent(), contentSender({incognito: true})],
        [manualSwitchIntent(), popupSender()],
    ]) {
        assert.equal(await harness.dispatch(message, sender), undefined);
    }
    assert.equal(harness.nativeMessages.length, 0);
});

test("rejects stale account-bound operations when native has no matching attempt", async () => {
    const harness = makeHarness({native: message => {
        assert.equal(message.replayOnly, true);
        return {id: message.id, name: message.name, error: "No matching attempt", errorCode: -32603};
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
    assert.equal(harness.nativeMessages.length, 1);
});

test("forwards an account-bound operation with current stored authorization", async () => {
    const address = "0x0000000000000000000000000000000000000001";
    const storage = new Map([["https://wallet.example", {
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
        const harness = makeHarness({native: message => {
            assert.equal(message.replayOnly, true);
            return {id: message.id, name: message.name, error: "No matching attempt", errorCode: -32603};
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
        assert.equal(harness.nativeMessages.length, 1, name);
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

test("generic dapp admission rejects every manual Switch Account shape", async () => {
    const message = {
        name: "switchAccount",
        provider: "unknown",
        body: {latestConfigurations: []},
    };
    const harness = makeHarness({native: () => {
        assert.fail("generic manual switch must not reach native");
    }});
    assert.equal(await harness.dispatch(request(31, {message})), undefined);
    assert.equal(await harness.dispatch(request(31, {
        manualSwitch: true,
        message,
    })), undefined);
    assert.equal(harness.nativeMessages.length, 0);
});

test("manual switch snapshots one current configuration lineage", async () => {
    const staleConfiguration = {
        provider: "ethereum",
        chainId: "0x1",
        results: ["0x0000000000000000000000000000000000000001"],
    };
    const storage = new Map([["https://wallet.example", {
        latestConfigurations: [staleConfiguration],
        revisions: {ethereum: 0, solana: 0},
        workflowVersion: 3,
    }]]);
    const harness = makeHarness({
        storage,
        native: message => nativeAcknowledgement(
            message.id,
            message.revisions
        ),
    });
    await harness.dispatch({
        subject: "disconnect",
        id: 80,
        provider: "ethereum",
        host: "wallet.example",
        configurationKey: "https://wallet.example",
        workflowVersion: 3,
    });

    const response = await harness.dispatch(
        manualSwitchIntent(),
        contentSender()
    );
    const admitted = harness.nativeMessages.at(-1).message;

    assert.equal(response.subject, "manualSwitchAcknowledged");
    assert.deepEqual(admitted.body, {latestConfigurations: []});
    assert.deepEqual(admitted.revisions, {ethereum: 1, solana: 0});
});

test("a blocked switch snapshot does not block another origin", async () => {
    let releaseBlockedRead;
    const blockedRead = new Promise(resolve => { releaseBlockedRead = resolve; });
    let blockedReadStarted = false;
    const harness = makeHarness({
        native: message => nativeAcknowledgement(message.id, message.revisions),
        storageGet(keys, values) {
            const requested = Array.isArray(keys) ? keys : [keys];
            if (requested.includes("https://blocked.example")) {
                blockedReadStarted = true;
                return blockedRead.then(() => values);
            }
            return values;
        },
    });
    const blocked = harness.dispatch(manualSwitchIntent({
        configurationKey: "https://blocked.example",
        host: "blocked.example",
    }), contentSender({
        id: 91,
        url: "https://blocked.example/dapp",
    }));
    await settle();
    assert.equal(blockedReadStarted, true);

    let otherSettled = false;
    const other = harness.dispatch(manualSwitchIntent({
        configurationKey: "https://other.example",
        host: "other.example",
    }), contentSender({
        id: 92,
        url: "https://other.example/dapp",
    })).then(response => {
        otherSettled = true;
        return response;
    });
    for (let attempt = 0; attempt < 10 && !otherSettled; attempt += 1) {
        await settle();
    }
    const progressedIndependently = otherSettled;
    releaseBlockedRead();
    const [blockedResponse, otherResponse] = await Promise.all([blocked, other]);

    assert.equal(progressedIndependently, true);
    assert.equal(blockedResponse.subject, "manualSwitchAcknowledged");
    assert.equal(otherResponse.subject, "manualSwitchAcknowledged");
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

test("lost signing acknowledgments recover committed results after disconnect and restart", async () => {
    const address = "0x0000000000000000000000000000000000000001";
    for (const [provider, name, body, configuration] of [
        ["ethereum", "signTransaction", {address, chainId: "0x1"}, {
            provider: "ethereum", chainId: "0x1", results: [address],
        }],
        ["solana", "signAndSendTransaction", {publicKey: firstSolanaPublicKey}, {
            provider: "solana", publicKey: firstSolanaPublicKey,
        }],
    ]) {
        const storage = new Map([["https://wallet.example", {
            latestConfigurations: [configuration],
            revisions: {ethereum: 0, solana: 0},
            workflowVersion: 3,
        }]]);
        let admitted;
        const native = message => {
            if (!message.subject) {
                if (!admitted) {
                    assert.equal(message.replayOnly, undefined);
                    admitted = clone(message);
                    return undefined;
                }
                assert.equal(message.replayOnly, true);
                assert.equal(message.enqueueAttempt, admitted.enqueueAttempt);
                assert.deepEqual(clone(message.body), admitted.body);
                return nativeAcknowledgement(message.id, admitted.revisions, false);
            }
            if (isResponseRead(message)) {
                return {
                    id: message.id, name, provider, result: "committed-transaction",
                    __bwApprovalCommitted: true,
                };
            }
        };
        const original = request(9, {message: {provider, name, body}});
        const first = makeHarness({storage, native});
        assert.equal(await first.dispatch(original), undefined);
        await first.dispatch({
            subject: "disconnect", id: 10, provider,
            host: "wallet.example", configurationKey: "https://wallet.example",
            workflowVersion: 3,
        });

        const restarted = makeHarness({storage, native});
        const acknowledgement = await restarted.dispatch(original);
        assert.equal(acknowledgement.requestToken, requestToken);
        assert.deepEqual(clone(acknowledgement.revisions), admitted.revisions);
        assert.equal(acknowledgement.approvalRequired, false);
        const response = await restarted.dispatch({
            subject: "getResponse", id: 9,
            configurationKey: "https://wallet.example", requestToken,
            revisions: acknowledgement.revisions, workflowVersion: 3,
        });
        assert.equal(response.result, "committed-transaction");
        assert.equal(response.__bwApprovalCommitted, true);
        assert.deepEqual(storage.get("https://wallet.example").latestConfigurations, []);
        assert.deepEqual(restarted.popupCalls, []);
    }
});

test("unauthorized recovery keeps retrying unavailable transport and does not cue active approvals", async () => {
    for (const reply of [undefined, nativeAcknowledgement(9)]) {
        const harness = makeHarness({native: message => {
            assert.equal(message.replayOnly, true);
            return reply;
        }});
        const response = await harness.dispatch(request(9, {message: {
            name: "signMessage",
            body: {address: "0x0000000000000000000000000000000000000001"},
        }}));
        assert.deepEqual(clone(response), reply);
        assert.deepEqual(harness.popupCalls, []);
        assert.deepEqual(harness.runtimeMessages, []);
    }
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
        if (isResponseRead(message)) {
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
    assert.deepEqual(
        harness.nativeMessages.findLast(value =>
            isResponseRead(value.message)
        ).message.revisions,
        {ethereum: 1, solana: 0}
    );
    assert.equal(response.errorCode, 4100);
    assert.deepEqual(clone(response.latestConfigurations), []);
});

test("reads, applies, and retains a native response", async () => {
    const storage = new Map;
    const native = message => {
        if (isResponseRead(message)) {
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

test("native errors cannot smuggle configuration mutations", async () => {
    const storage = new Map;
    const harness = makeHarness({storage, native: message => ({
        id: message.id,
        name: message.name,
        provider: message.provider,
        error: "Canceled",
        errorCode: 4001,
        configurationToStore: {
            provider: "ethereum",
            chainId: "0x1",
            results: ["0x0000000000000000000000000000000000000001"],
        },
    })});

    const response = await harness.dispatch(request(24));
    assert.equal(response.errorCode, -32603);
    assert.equal(storage.has("https://wallet.example"), false);
});

test("malformed native configuration mutations fail closed before storage", async () => {
    const harness = makeHarness({native: message => isResponseRead(message) ? {
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
    assert.deepEqual(providerStateWrites(harness), []);
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
        assert.deepEqual(providerStateWrites(harness), []);
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
    assert.deepEqual(providerStateWrites(harness), []);
    assert.deepEqual(harness.tabMessages, []);
});

test("replays an already-applied response without advancing revisions again", async () => {
    const storage = new Map;
    const native = message => isResponseRead(message) ? {
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
    const native = message => isResponseRead(message) ? {
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
        "acknowledgeResponse",
        "getResponse",
        "acknowledgeResponse",
    ]);
});

test("completion acknowledgement follows persistence without delaying content", async () => {
    const fixture = completedAccountFixture();
    let releaseWrite;
    const write = new Promise(resolve => { releaseWrite = resolve; });
    let acknowledge;
    const acknowledgement = new Promise(resolve => { acknowledge = resolve; });
    const harness = makeHarness({
        native: () => fixture.response,
        storageSet: values => values[fixture.read.configurationKey] ? write : undefined,
        acknowledgeResponse: () => acknowledgement,
    });
    const reading = harness.dispatch(fixture.read);
    await settle();
    assert.equal(harness.nativeMessages.some(value =>
        value.message.subject === "acknowledgeResponse"
    ), false);

    releaseWrite();
    const response = await reading;
    assert.deepEqual(clone(response.results), fixture.configuration.results);
    assert.deepEqual(harness.storage.get(fixture.read.configurationKey).revisions, {
        ethereum: 1,
        solana: 0,
    });
    let popupSettled = false;
    const applying = harness.dispatch(fixture.apply, popupSender()).then(value => {
        popupSettled = true;
        return value;
    });
    await settle();
    assert.equal(popupSettled, false);
    assert.deepEqual(harness.nativeMessages.map(value => value.message.subject), [
        "getResponse",
        "acknowledgeResponse",
        "getResponse",
        "acknowledgeResponse",
    ]);
    assert.deepEqual(harness.nativeMessages[1].message, {
        subject: "acknowledgeResponse",
        id: fixture.read.id,
        configurationKey: fixture.read.configurationKey,
        requestToken,
        workflowVersion: 3,
        __bwPrivateBrowsing: false,
    });
    acknowledge({id: fixture.read.id, acknowledged: true});
    assert.deepEqual(clone(await applying), {applied: true});
    assert.equal(harness.storage.get(fixture.read.configurationKey).revisions.ethereum, 1);
});

test("delayed acknowledgement does not replay configuration from before a disconnect", async () => {
    const fixture = completedAccountFixture();
    let acknowledge;
    const acknowledgement = new Promise(resolve => { acknowledge = resolve; });
    const harness = makeHarness({
        native: () => ({...fixture.response, __bwApprovalCommitted: true}),
        acknowledgeResponse: () => acknowledgement,
        tabs: [contentSender().tab],
        sendTabMessage() { throw new Error("Broadcast missed"); },
    });
    const initial = await harness.dispatch(fixture.read);
    assert.equal(initial.revisions.ethereum, 1);
    const disconnected = await harness.dispatch({
        subject: "disconnect",
        id: 24,
        provider: "ethereum",
        host: "wallet.example",
        configurationKey: fixture.read.configurationKey,
        workflowVersion: 3,
    });
    assert.equal(disconnected.result, null);
    assert.equal(harness.tabMessages.at(-1).message.revisions.ethereum, 2);

    const replay = await harness.dispatch(fixture.read);
    assert.deepEqual(clone(replay.latestConfigurations), []);
    assert.deepEqual(clone(replay.revisions), {ethereum: 2, solana: 0});
    assert.deepEqual(clone(replay.results), fixture.configuration.results);
    assert.equal(harness.nativeMessages.filter(value =>
        isResponseRead(value.message)
    ).length, 2);
    acknowledge({id: fixture.read.id, acknowledged: true});
    await settle();
});

test("full popup and worker recover interrupted durable batches without reviving disconnected accounts", async () => {
    const storage = new Map;
    const nativeStore = completedResponseStore(33);
    const firstRecord = nativeStore.records.get(1);
    const configurationKey = firstRecord.identity.configurationKey;
    const acknowledgementStarted = deferred();
    const interrupted = makeHarness({
        storage,
        native: nativeStore.native,
        acknowledgeResponse() {
            acknowledgementStarted.resolve();
            return new Promise(() => {});
        },
    });
    const firstPopup = openRecoveryPopup(interrupted, nativeStore.native);
    await acknowledgementStarted.promise;
    assert.equal(storage.get(configurationKey).revisions.ethereum, 1);
    assert.equal(firstRecord.acknowledged, false);
    assert.equal(firstPopup.element("screen-loading").classList.contains("hidden"), false);
    firstPopup.close();

    let failingAcknowledgment = 17;
    const restarted = makeHarness({
        storage,
        native: nativeStore.native,
        acknowledgeResponse: message => message.id === failingAcknowledgment
            ? undefined
            : nativeStore.acknowledge(message),
        tabs: [contentSender().tab],
        sendTabMessage() { throw new Error("Broadcast missed"); },
    });
    const disconnected = await restarted.dispatch({
        subject: "disconnect",
        id: 100,
        provider: "ethereum",
        host: "wallet.example",
        configurationKey,
        workflowVersion: 3,
    });
    assert.equal(disconnected.result, null);
    const reopened = openRecoveryPopup(restarted, nativeStore.native);
    await reopened.waitForIdleText("Failed to load");
    assert.deepEqual(nativeStore.pageSizes, [16, 16, 16]);
    assert.deepEqual([...nativeStore.records.values()]
        .filter(record => record.acknowledged).map(record => record.identity.id),
    Array.from({length: 16}, (_, index) => index + 1));
    assert.equal(reopened.element("idle-check-status").classList.contains("hidden"), false);
    assert.equal(reopened.element("idle-check-status").disabled, false);
    assert.equal(reopened.element("idle-switch-account").disabled, true);
    assert.deepEqual(storage.get(configurationKey).latestConfigurations, []);
    assert.equal(storage.get(configurationKey).revisions.ethereum, 2);

    failingAcknowledgment = null;
    await reopened.refresh();
    await reopened.waitForIdleText("Not connected");
    assert.deepEqual(nativeStore.pageSizes, [16, 16, 16, 16, 1, 0]);
    assert.equal(reopened.element("idle-check-status").classList.contains("hidden"), true);
    assert.ok([...nativeStore.records.values()].every(record => record.acknowledged));
    assert.equal(nativeStore.records.size, 33);
    const replay = await restarted.dispatch(firstRecord.read);
    assert.deepEqual(clone(replay.latestConfigurations), []);
    assert.deepEqual(clone(replay.revisions), {ethereum: 2, solana: 0});
    assert.deepEqual(storage.get(configurationKey).latestConfigurations, []);
    assert.equal(storage.get(configurationKey).revisions.ethereum, 2);
    reopened.close();
});

test("failed configuration persistence never acknowledges a completion", async () => {
    const fixture = completedAccountFixture();
    const harness = makeHarness({
        native: () => fixture.response,
        storageSet(values) {
            if (values[fixture.read.configurationKey]) {
                throw new Error("storage unavailable");
            }
        },
        acknowledgeResponse: () => assert.fail("must persist before acknowledgement"),
    });
    assert.equal(await harness.dispatch(fixture.apply, popupSender()), undefined);
    assert.equal(harness.nativeMessages.some(value =>
        value.message.subject === "acknowledgeResponse"
    ), false);
});

test("failed acknowledgements retry after worker restart without advancing revisions", async () => {
    const fixture = completedAccountFixture();
    const failures = [
        undefined,
        {id: fixture.read.id, acknowledged: false},
        {id: fixture.read.id, missing: false},
        {id: fixture.read.id + 1, acknowledged: true},
        {id: fixture.read.id, acknowledged: true, state: "working"},
        new Error("native unavailable"),
    ];
    for (const failure of failures) {
        const storage = new Map;
        const native = () => fixture.response;
        const first = makeHarness({
            storage,
            native,
            acknowledgeResponse() {
                if (failure instanceof Error) { throw failure; }
                return failure;
            },
        });
        assert.equal(await first.dispatch(fixture.apply, popupSender()), undefined);
        assert.equal(storage.get(fixture.read.configurationKey).revisions.ethereum, 1);

        const restarted = makeHarness({storage, native});
        assert.deepEqual(clone(await restarted.dispatch(fixture.apply, popupSender())), {
            applied: true,
        });
        assert.equal(storage.get(fixture.read.configurationKey).revisions.ethereum, 1);
        assert.deepEqual(providerStateWrites(restarted), []);
        const replay = await restarted.dispatch(fixture.read);
        assert.deepEqual(clone(replay.results), fixture.configuration.results);
    }
});

test("an already absent acknowledgment completes popup recovery", async () => {
    const fixture = completedAccountFixture();
    const harness = makeHarness({
        native: () => fixture.response,
        acknowledgeResponse: message => ({id: message.id, missing: true}),
    });
    assert.deepEqual(clone(await harness.dispatch(fixture.apply, popupSender())), {
        applied: true,
    });
});

test("acknowledgment timeout never loses an ordinary committed transaction result", async () => {
    const fixture = completedAccountFixture();
    const timers = [];
    const harness = makeHarness({
        native: () => ({
            id: fixture.read.id,
            name: "signTransaction",
            provider: "ethereum",
            result: "0xsubmitted-transaction-hash",
            __bwApprovalCommitted: true,
        }),
        acknowledgeResponse: () => new Promise(() => {}),
        scheduleTimeout(callback, delay) {
            const timer = {callback, delay};
            timers.push(timer);
            return timer;
        },
        cancelTimeout(timer) { if (timer) { timer.cancelled = true; } },
    });
    const response = await harness.dispatch(fixture.read);
    assert.equal(response.result, "0xsubmitted-transaction-hash");
    const applying = harness.dispatch(fixture.apply, popupSender());
    await settle();
    const timeouts = timers.filter(timer => timer.delay === 5000 && !timer.cancelled);
    assert.equal(timeouts.length, 2);
    timeouts.forEach(timer => timer.callback());
    assert.equal(await applying, undefined);
});

test("popup receives an exact missing completed response", async () => {
    const harness = makeHarness({
        native: message => isResponseRead(message)
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
    const native = message => isResponseRead(message) ? {
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
    assert.deepEqual(
        harness.nativeMessages.findLast(value =>
            isResponseRead(value.message)
        ).message.revisions,
        {ethereum: 1, solana: 0}
    );
    assert.equal(response.errorCode, 4100);
    assert.equal(response.__bigWalletSuppressProviderUpdate, undefined);
    assert.deepEqual(clone(response.latestConfigurations), []);
    assert.deepEqual(
        harness.storage.get("https://wallet.example").latestConfigurations,
        []
    );
});

test("provider revision overflow fails closed without corrupting storage", async () => {
    const maximum = Number.MAX_SAFE_INTEGER;
    const originalAddress = "0x0000000000000000000000000000000000000001";
    const replacementAddress = "0x0000000000000000000000000000000000000002";
    const initial = {
        latestConfigurations: [{
            provider: "ethereum",
            chainId: "0x1",
            results: [originalAddress],
        }],
        revisions: {ethereum: maximum, solana: 0},
        workflowVersion: 3,
    };
    const storage = new Map([["https://wallet.example", clone(initial)]]);
    const harness = makeHarness({
        storage,
        native: message => isResponseRead(message) ? {
            id: 120,
            name: "requestAccounts",
            provider: "ethereum",
            configurationToStore: {
                provider: "ethereum",
                chainId: "0x1",
                results: [replacementAddress],
            },
        } : undefined,
    });

    const response = await harness.dispatch({
        subject: "getResponse",
        id: 120,
        configurationKey: "https://wallet.example",
        requestToken,
        revisions: {ethereum: maximum, solana: 0},
        workflowVersion: 3,
    });
    const disconnected = await harness.dispatch({
        subject: "disconnect",
        id: 121,
        provider: "ethereum",
        host: "wallet.example",
        configurationKey: "https://wallet.example",
        workflowVersion: 3,
    });
    const readable = await harness.dispatch({
        subject: "getLatestConfiguration",
        host: "wallet.example",
        configurationKey: "https://wallet.example",
        workflowVersion: 3,
    });

    assert.equal(response.errorCode, 4100);
    assert.equal(disconnected.errorCode, -32603);
    assert.deepEqual(clone(storage.get("https://wallet.example")), initial);
    assert.deepEqual(clone(readable.revisions), {
        ethereum: maximum,
        solana: 0,
    });
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
        native: message => isResponseRead(message) ? {
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
        providersToDisconnect: [],
        __bwApprovalCommitted: true,
    };
    const harness = makeHarness({
        storage,
        native: message => isResponseRead(message) ? response : undefined,
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
        reauthorizationRevision: 1,
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
            reauthorizationRevision: 1,
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
    const harness = makeHarness({native: message => isResponseRead(message) ? {
        id: 53,
        name: "switchAccount",
        provider: "multiple",
        bodies: [
            {
                provider: "ethereum",
                chainId: "0x1",
                results: ["0x0000000000000000000000000000000000000002"],
            },
            {provider: "solana", publicKey: secondSolanaPublicKey},
        ],
        providersToDisconnect: [],
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
        native: message => isResponseRead(message) ? {
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
    assert.deepEqual(storage.get("https://wallet.example"), {
        latestConfigurations: [],
        revisions: {ethereum: 1, solana: 0},
        workflowVersion: 3,
    });
});

test("concurrent response polls share one native read and exact revisions", async () => {
    let resolveNative;
    const nativeResponse = new Promise(resolve => { resolveNative = resolve; });
    let nativeReadCount = 0;
    const harness = makeHarness({native: message => {
        if (message.subject !== "getResponse") { return undefined; }
        nativeReadCount += 1;
        return nativeResponse;
    }});
    const read = {
        subject: "getResponse",
        id: 73,
        configurationKey: "https://wallet.example",
        requestToken,
        revisions: {ethereum: 0, solana: 0},
        workflowVersion: 3,
    };
    const polls = Array.from({length: 12}, () => harness.dispatch(read));
    await settle();

    assert.equal(nativeReadCount, 1);
    assert.equal(await harness.dispatch({
        ...read,
        revisions: {ethereum: 1, solana: 0},
    }), undefined);
    assert.equal(nativeReadCount, 1);

    resolveNative({
        id: 73,
        name: "signMessage",
        provider: "ethereum",
        error: "Rejected",
        errorCode: 4001,
    });
    const responses = await Promise.all(polls);
    for (const response of responses) {
        assert.deepEqual(clone(response), clone(responses[0]));
    }
    assert.equal((await harness.dispatch(read)).errorCode, 4001);
    assert.equal(nativeReadCount, 2);
});

test("a rejected response flight is cleared for the next poll", async () => {
    let nativeReadCount = 0;
    const harness = makeHarness({native: message => {
        if (message.subject !== "getResponse") { return undefined; }
        nativeReadCount += 1;
        return Promise.reject(new Error("native unavailable"));
    }});
    const read = {
        subject: "getResponse",
        id: 75,
        configurationKey: "https://wallet.example",
        requestToken,
        revisions: {ethereum: 0, solana: 0},
        workflowVersion: 3,
    };

    assert.deepEqual(await Promise.all([
        harness.dispatch(read),
        harness.dispatch(read),
    ]), [undefined, undefined]);
    assert.equal(nativeReadCount, 1);
    assert.equal(await harness.dispatch(read), undefined);
    assert.equal(nativeReadCount, 2);
});

test("native finalization rejects mutations while new tabs read committed configuration", async () => {
    const address = "0x0000000000000000000000000000000000000001";
    const initial = {
        latestConfigurations: [{
            provider: "ethereum",
            chainId: "0x1",
            results: [address],
        }],
        revisions: {ethereum: 2, solana: 4},
        workflowVersion: 3,
    };
    let resolveNative;
    const nativeResponse = new Promise(resolve => { resolveNative = resolve; });
    const harness = makeHarness({
        storage: new Map([["https://wallet.example", clone(initial)]]),
        native: message => isResponseRead(message)
            ? nativeResponse
            : undefined,
    });
    const applying = harness.dispatch({
        subject: "getResponse",
        id: 74,
        configurationKey: "https://wallet.example",
        requestToken,
        revisions: {ethereum: 2, solana: 4},
        workflowVersion: 3,
    });
    await settle();
    let disconnectResponse;
    const disconnecting = harness.dispatch({
        subject: "disconnect",
        id: 76,
        provider: "ethereum",
        host: "wallet.example",
        configurationKey: "https://wallet.example",
        workflowVersion: 3,
    }).then(value => { disconnectResponse = value; });
    await settle();
    await disconnecting;
    assert.equal(disconnectResponse.errorCode, -32603);
    assert.deepEqual(harness.timerDelays, [5000, 180_000]);

    let configuration;
    const reading = harness.dispatch({
        subject: "getLatestConfiguration",
        host: "wallet.example",
        configurationKey: "https://wallet.example",
        workflowVersion: 3,
    }, contentSender({id: 77, url: "https://wallet.example/new-tab"})).then(value => {
        configuration = value;
    });
    await settle();
    assert.deepEqual(clone(configuration), {
        latestConfigurations: [{...initial.latestConfigurations[0], accountRevision: 2}],
        revisions: initial.revisions,
    });
    assert.equal(providerStateWrites(harness).length, 0);

    resolveNative({
        id: 74,
        name: "requestAccounts",
        provider: "ethereum",
        configurationToStore: {
            provider: "ethereum",
            chainId: "0x1",
            results: [address],
        },
    });
    await applying;
    await reading;
    const disconnected = await harness.dispatch({
        subject: "disconnect",
        id: 78,
        provider: "ethereum",
        host: "wallet.example",
        configurationKey: "https://wallet.example",
        workflowVersion: 3,
    });
    assert.equal(disconnected.result, null);
    assert.deepEqual(harness.storage.get("https://wallet.example"), {
        latestConfigurations: [],
        revisions: {ethereum: 4, solana: 4},
        workflowVersion: 3,
    });
});

test("the finalization ceiling releases a blocked configuration lineage", async () => {
    const harness = makeHarness({
        native: message => isResponseRead(message)
            ? new Promise(() => {})
            : undefined,
        scheduleTimeout(callback, delay) {
            if (delay === 180_000) { queueMicrotask(callback); }
            return delay;
        },
    });
    const response = await harness.dispatch({
        subject: "getResponse",
        id: 75,
        configurationKey: "https://wallet.example",
        requestToken,
        revisions: {ethereum: 0, solana: 0},
        workflowVersion: 3,
    });
    const disconnected = await harness.dispatch({
        subject: "disconnect",
        id: 77,
        provider: "ethereum",
        host: "wallet.example",
        configurationKey: "https://wallet.example",
        workflowVersion: 3,
    });

    assert.equal(response, undefined);
    assert.equal(disconnected.result, null);
    assert.equal(harness.timerDelays.includes(180_000), true);
});

test("the finalization ceiling releases a switch lineage for another attempt", async () => {
    const storage = new Map;
    const harness = makeHarness({
        storage,
        native: message => isResponseRead(message)
            ? new Promise(() => {})
            : nativeAcknowledgement(message.id, message.revisions),
        scheduleTimeout(callback, delay) {
            if (delay === 180_000) { queueMicrotask(callback); }
            return delay;
        },
    });
    const acknowledged = await harness.dispatch(
        manualSwitchIntent(), contentSender()
    );
    await harness.dispatch({
        subject: "responseReady",
        id: acknowledged.id,
        workflowVersion: 3,
    }, {});
    const disconnected = await harness.dispatch({
        subject: "disconnect",
        id: 79,
        provider: "ethereum",
        host: "wallet.example",
        configurationKey: "https://wallet.example",
        workflowVersion: 3,
    });

    const repeated = await harness.dispatch(manualSwitchIntent(), contentSender());
    assert.equal(repeated.id, acknowledged.id);
    assert.equal(disconnected.result, null);
    assert.equal(harness.timerDelays.includes(180_000), true);
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
    assert.equal(readCount, 6);
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

test("reads main host configurations without writes and migrates on the next operation", async () => {
    const configuration = {
        provider: "solana",
        publicKey: firstSolanaPublicKey,
    };
    for (const value of [configuration, [configuration], {latestConfigurations: [configuration]}]) {
        const storage = new Map([["wallet.example", value]]);
        const harness = makeHarness({storage});
        const response = await harness.dispatch({
            subject: "getLatestConfiguration",
            host: "wallet.example",
            configurationKey: "https://wallet.example",
            workflowVersion: 3,
        });
        assert.equal(response.latestConfigurations[0].publicKey, firstSolanaPublicKey);
        assert.deepEqual(clone(response.revisions), {ethereum: 0, solana: 0});
        assert.deepEqual(storage.get("wallet.example"), value);
        assert.equal(storage.has("https://wallet.example"), false);
        assert.deepEqual(harness.storageWrites, []);
        assert.deepEqual(harness.storageRemovals, []);

        const disconnected = await harness.dispatch({
            subject: "disconnect",
            id: 94,
            provider: "ethereum",
            host: "wallet.example",
            configurationKey: "https://wallet.example",
            workflowVersion: 3,
        });
        assert.equal(disconnected.result, null);
        assert.equal(storage.has("wallet.example"), false);
        assert.deepEqual(storage.get("https://wallet.example"), {
            latestConfigurations: [configuration],
            revisions: {ethereum: 1, solana: 0},
            workflowVersion: 3,
        });
        assert.equal(harness.storageWrites.length, 1);
        assert.deepEqual(harness.storageRemovals, ["wallet.example"]);
    }
});

test("main host migration removes the source only after successful persistence", async () => {
    for (const succeeds of [true, false]) {
        const value = [{provider: "solana", publicKey: firstSolanaPublicKey}];
        const storage = new Map([["wallet.example", value]]);
        const write = deferred();
        const harness = makeHarness({storage, storageSet: () => write.promise});
        const operation = harness.dispatch({
            subject: "disconnect",
            id: 94,
            provider: "ethereum",
            host: "wallet.example",
            configurationKey: "https://wallet.example",
            workflowVersion: 3,
        });
        await settle();
        assert.equal(harness.storageWrites.length, 1);
        assert.deepEqual(storage.get("wallet.example"), value);
        assert.deepEqual(harness.storageRemovals, []);
        if (succeeds) {
            write.resolve();
        } else {
            write.reject(new Error("Storage unavailable"));
        }
        const response = await operation;
        assert.equal(storage.has("wallet.example"), !succeeds);
        assert.equal(response.errorCode, succeeds ? undefined : -32603);
    }
});

test("unpublished stored wrappers fail closed at host and origin keys", async () => {
    const latestConfigurations = [{provider: "solana", publicKey: firstSolanaPublicKey}];
    const values = [
        ...[1, 2, 4].map(workflowVersion => ({
            latestConfigurations,
            revisions: {ethereum: 4, solana: 6},
            workflowVersion,
        })),
        {
            latestConfigurations,
            bridgeState: {version: 2, revision: 4, solanaAuthorizationEpoch: 6},
        },
        {
            latestConfigurations,
            bridgeState: {},
            revisions: {ethereum: 4, solana: 6},
            workflowVersion: 3,
        },
    ];
    for (const key of ["wallet.example", "https://wallet.example"]) {
        for (const value of values) {
            const storage = new Map([[key, value]]);
            const harness = makeHarness({storage});
            const response = await harness.dispatch({
                subject: "getLatestConfiguration",
                host: "wallet.example",
                configurationKey: "https://wallet.example",
                workflowVersion: 3,
            });
            assert.equal(response.configurationReadFailed, true);
            assert.deepEqual(storage.get(key), value);
            assert.deepEqual(harness.storageWrites, []);
            assert.deepEqual(harness.storageRemovals, []);
        }
    }
});

test("invalid origin state never falls back to main host authorization", async () => {
    const configuration = {provider: "solana", publicKey: firstSolanaPublicKey};
    for (const value of [
        configuration,
        [configuration],
        {latestConfigurations: [configuration]},
        {latestConfigurations: [configuration], revisions: {}, workflowVersion: 3},
    ]) {
        const storage = new Map([
            ["wallet.example", [configuration]],
            ["https://wallet.example", value],
        ]);
        const harness = makeHarness({storage});
        const response = await harness.dispatch({
            subject: "getLatestConfiguration",
            host: "wallet.example",
            configurationKey: "https://wallet.example",
            workflowVersion: 3,
        });
        assert.equal(response.configurationReadFailed, true);
        assert.deepEqual(storage.get("wallet.example"), [configuration]);
        assert.deepEqual(storage.get("https://wallet.example"), value);
        assert.deepEqual(harness.storageWrites, []);
        assert.deepEqual(harness.storageRemovals, []);
    }
});

test("canonicalizes positive main Ethereum quantities across host storage shapes", async () => {
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
            },
        },
    ];

    for (const item of cases) {
        const storage = new Map([["wallet.example", item.value]]);
        const harness = makeHarness({storage});
        const response = await harness.dispatch({
            subject: "getLatestConfiguration",
            host: "wallet.example",
            configurationKey: "https://wallet.example",
            workflowVersion: 3,
        });

        assert.equal(response.latestConfigurations[0].chainId, item.expected);
        assert.deepEqual(storage.get("wallet.example"), item.value);
        assert.deepEqual(harness.storageWrites, []);
        assert.deepEqual(harness.storageRemovals, []);

        const disconnected = await harness.dispatch({
            subject: "disconnect",
            id: 95,
            provider: "solana",
            host: "wallet.example",
            configurationKey: "https://wallet.example",
            workflowVersion: 3,
        });
        assert.equal(disconnected.result, null);
        assert.equal(
            storage.get("https://wallet.example").latestConfigurations[0].chainId,
            item.expected
        );
        assert.equal(storage.get("https://wallet.example").workflowVersion, 3);
        assert.equal(harness.storageWrites.length, 1);
    }
});

test("main zero malformed and over-native-max chains fail closed", async () => {
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
        const storage = new Map([["wallet.example", value]]);
        const harness = makeHarness({storage});
        const response = await harness.dispatch({
            subject: "getLatestConfiguration",
            host: "wallet.example",
            configurationKey: "https://wallet.example",
            workflowVersion: 3,
        });

        assert.equal(response.configurationReadFailed, true);
        assert.deepEqual(harness.storageWrites, []);
        assert.deepEqual(storage.get("wallet.example"), value);
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

test("popup approval rejects disconnect until native execution settles", async () => {
    let resolveApproval;
    const approvalGate = new Promise(resolve => { resolveApproval = resolve; });
    const harness = makeHarness({native: message => {
        return message.subject === "approveRequest" ? approvalGate : undefined;
    }});
    const approving = harness.dispatch(approvalProxy(91), popupSender());
    await settle();
    assert.equal(harness.nativeMessages.length, 1);
    assert.deepEqual(harness.nativeMessages[0].message.payload.revisions, {
        ethereum: 0,
        solana: 0,
    });

    const blocked = await harness.dispatch({
        subject: "disconnect",
        id: 92,
        provider: "ethereum",
        host: "wallet.example",
        configurationKey: "https://wallet.example",
        workflowVersion: 3,
    });
    assert.equal(blocked.errorCode, -32603);

    resolveApproval({status: "ok"});
    assert.deepEqual(clone(await approving), {status: "ok"});
    const disconnected = await harness.dispatch({
        subject: "disconnect",
        id: 92,
        provider: "ethereum",
        host: "wallet.example",
        configurationKey: "https://wallet.example",
        workflowVersion: 3,
    });
    assert.equal(disconnected.result, null);
});

function timedApprovalHarness(options = {}) {
    let now = 1_700_000_000_000;
    let nextTimer = 0;
    const timers = new Map;
    const harness = makeHarness({
        ...options,
        dateNow: () => now,
        scheduleTimeout(callback, delay) {
            const id = ++nextTimer;
            timers.set(id, {callback, due: now + delay});
            return id;
        },
        cancelTimeout(id) { timers.delete(id); },
    });
    return {
        ...harness,
        timers,
        now: () => now,
        async advance(milliseconds) {
            const target = now + milliseconds;
            await settle();
            while (true) {
                const next = [...timers].sort((a, b) => a[1].due - b[1].due)[0];
                if (!next || next[1].due > target) { break; }
                now = next[1].due;
                timers.delete(next[0]);
                next[1].callback();
                await settle();
            }
            now = target;
            await settle();
        },
    };
}

test("popup approval waits for a response poll and preserves its review token", async () => {
    for (const nativeResult of [{status: "ok"}, {status: "staleReview"}]) {
        let resolvePoll;
        const pollGate = new Promise(resolve => { resolvePoll = resolve; });
        const harness = timedApprovalHarness({native: message =>
            isResponseRead(message) ? pollGate : nativeResult,
        });
        const polling = harness.dispatch({
            subject: "getResponse",
            id: 108,
            configurationKey: "https://wallet.example",
            requestToken,
            revisions: {ethereum: 0, solana: 0},
            workflowVersion: 3,
        });
        await settle();
        const approving = harness.dispatch(approvalProxy(108), popupSender());
        await harness.advance(200);
        assert.equal(harness.nativeMessages.length, 1);

        resolvePoll(undefined);
        await polling;
        await harness.advance(100);
        assert.deepEqual(clone(await approving), nativeResult);
        const approval = harness.nativeMessages[1].message;
        assert.equal(approval.subject, "approveRequest");
        assert.equal(approval.reviewToken, reviewToken);
        assert.equal(approval.payload.executionDeadline, harness.now() + 150_000);
        assert.equal(harness.nativeMessages.length, 2);
        assert.equal(harness.timers.size, 0);
        assert.equal([...harness.storage.keys()].some(key =>
            key.startsWith(approvalLeaseStoragePrefix)
        ), false);
    }
});

test("popup approval can acquire a persisted lease after its expiry", async () => {
    const expiresAt = 1_700_000_000_500;
    const leaseKey = `${approvalLeaseStoragePrefix}wallet.example`;
    const storage = new Map([[leaseKey, {
        configurationKey: "wallet.example",
        issuedAt: expiresAt - 160_000,
        executionDeadline: expiresAt - 10_000,
        expiresAt,
        revisions: {ethereum: 0, solana: 0},
        token: attempt,
        workflowVersion: 3,
    }]]);
    const harness = timedApprovalHarness({
        storage,
        native: () => ({status: "ok"}),
    });
    const approving = harness.dispatch(approvalProxy(109), popupSender());
    await harness.advance(499);
    assert.equal(harness.nativeMessages.length, 0);
    await harness.advance(1);
    assert.deepEqual(clone(await approving), {status: "ok"});
    assert.equal(harness.nativeMessages.length, 1);
    assert.equal(storage.has(leaseKey), false);
    assert.equal(harness.timers.size, 0);
});

test("popup approval stops waiting after five seconds without removing another lease", async () => {
    const issuedAt = 1_700_000_000_000;
    const leaseKey = `${approvalLeaseStoragePrefix}wallet.example`;
    const lease = {
        configurationKey: "wallet.example",
        issuedAt,
        executionDeadline: issuedAt + 150_000,
        expiresAt: issuedAt + 160_000,
        revisions: {ethereum: 0, solana: 0},
        token: attempt,
        workflowVersion: 3,
    };
    const storage = new Map([[leaseKey, lease]]);
    const harness = timedApprovalHarness({
        storage,
        native: () => assert.fail("timed-out approval must never reach native"),
    });
    let settled = false;
    const approving = harness.dispatch(approvalProxy(110), popupSender())
        .then(result => { settled = true; return result; });
    await harness.advance(4999);
    assert.equal(settled, false);
    await harness.advance(1);
    assert.equal(await approving, undefined);
    assert.deepEqual(storage.get(leaseKey), lease);
    assert.equal(harness.timers.size, 0);
    await harness.advance(190_000);
    assert.equal(harness.nativeMessages.length, 0);
});

test("late approval lease storage never dispatches and cleans up only its own lease", async () => {
    for (const stage of ["read", "write", "replacement"]) {
        const storage = new Map;
        const leaseKey = `${approvalLeaseStoragePrefix}wallet.example`;
        let releaseStorage;
        const storageGate = new Promise(resolve => { releaseStorage = resolve; });
        const harness = timedApprovalHarness({
            storage,
            storageGet(keys, values) {
                return stage === "read" && keys === leaseKey
                    ? storageGate.then(() => values)
                    : values;
            },
            storageSet(values) {
                return stage !== "read" && values[leaseKey]
                    ? storageGate
                    : undefined;
            },
            native: () => assert.fail("late storage must never dispatch approval"),
        });
        const approving = harness.dispatch(approvalProxy(111), popupSender());
        await harness.advance(5000);
        assert.equal(await approving, undefined);
        const replacementToken = "11111111111111111111111111111111";
        if (stage === "replacement") {
            storage.set(leaseKey, {...storage.get(leaseKey), token: replacementToken});
        }
        releaseStorage();
        await settle();
        await settle();
        assert.equal(harness.nativeMessages.length, 0);
        assert.equal(harness.timers.size, 0);
        if (stage === "replacement") {
            assert.equal(storage.get(leaseKey).token, replacementToken);
        } else {
            assert.equal(storage.has(leaseKey), false);
        }
    }
});

test("a stalled popup approval releases its origin after the long timeout", async () => {
    const harness = makeHarness({
        native: message => message.subject === "approveRequest"
            ? new Promise(() => {})
            : undefined,
        scheduleTimeout(callback, delay) {
            if (delay === 180_000) { queueMicrotask(callback); }
            return delay;
        },
    });
    const approval = await harness.dispatch(approvalProxy(92), popupSender());
    const disconnected = await harness.dispatch({
        subject: "disconnect",
        id: 93,
        provider: "ethereum",
        host: "wallet.example",
        configurationKey: "https://wallet.example",
        workflowVersion: 3,
    });

    assert.equal(approval, undefined);
    assert.equal(disconnected.result, null);
    assert.equal(harness.timerDelays.includes(180_000), true);
});

test("a durable approval lease blocks revision changes after worker restart", async () => {
    const now = 1_700_000_000_000;
    const storage = new Map;
    let resolveApproval;
    const approvalGate = new Promise(resolve => { resolveApproval = resolve; });
    const first = makeHarness({
        dateNow: () => now,
        storage,
        native: message => message.subject === "approveRequest"
            ? approvalGate
            : undefined,
    });
    const approving = first.dispatch(approvalProxy(96), popupSender());
    await settle();
    const leaseEntry = [...storage.entries()].find(([key]) =>
        key.startsWith(approvalLeaseStoragePrefix)
    );
    assert.ok(leaseEntry);
    assert.deepEqual(Object.keys(leaseEntry[1]).sort(), [
        "configurationKey", "executionDeadline", "expiresAt", "issuedAt",
        "revisions", "token", "workflowVersion",
    ]);
    assert.equal(leaseEntry[1].issuedAt, now);
    assert.equal(leaseEntry[1].executionDeadline, now + 150_000);
    assert.equal(leaseEntry[1].expiresAt, now + 160_000);
    assert.deepEqual(leaseEntry[1].revisions, {ethereum: 0, solana: 0});

    const restarted = makeHarness({dateNow: () => now, storage});
    const blocked = await restarted.dispatch({
        subject: "disconnect",
        id: 97,
        provider: "ethereum",
        host: "wallet.example",
        configurationKey: "https://wallet.example",
        workflowVersion: 3,
    });
    assert.deepEqual(clone(blocked), {
        id: 97,
        name: "revokePermissions",
        provider: "ethereum",
        error: "Failed to revoke permissions",
        errorCode: -32603,
    });
    assert.equal(storage.has(leaseEntry[0]), true);

    resolveApproval({status: "ok"});
    assert.deepEqual(clone(await approving), {status: "ok"});
    assert.equal(storage.has(leaseEntry[0]), false);
    const disconnected = await restarted.dispatch({
        subject: "disconnect",
        id: 98,
        provider: "ethereum",
        host: "wallet.example",
        configurationKey: "https://wallet.example",
        workflowVersion: 3,
    });
    assert.equal(disconnected.result, null);
});

test("normal finalization keeps revisions leased across worker restart", async () => {
    const now = 1_700_000_000_000;
    const storage = new Map;
    let resolveNative;
    const nativeResponse = new Promise(resolve => { resolveNative = resolve; });
    const request = {
        subject: "getResponse",
        id: 105,
        configurationKey: "https://wallet.example",
        requestToken,
        revisions: {ethereum: 0, solana: 0},
        workflowVersion: 3,
    };
    const first = makeHarness({
        dateNow: () => now,
        storage,
        native: message => isResponseRead(message)
            ? nativeResponse
            : undefined,
    });
    const finalizing = first.dispatch(request);
    await settle();

    assert.deepEqual(first.nativeMessages[0].message.revisions, {
        ethereum: 0,
        solana: 0,
    });
    assert.equal(
        first.nativeMessages[0].message.executionDeadline,
        now + 160_000
    );
    const restarted = makeHarness({
        dateNow: () => now,
        storage,
        native: () => assert.fail("a busy lease must not call native twice"),
    });
    assert.equal(await restarted.dispatch(request), undefined);
    const blocked = await restarted.dispatch({
        subject: "disconnect",
        id: 106,
        provider: "ethereum",
        host: "wallet.example",
        configurationKey: "https://wallet.example",
        workflowVersion: 3,
    });
    assert.equal(blocked.errorCode, -32603);

    resolveNative({
        id: 105,
        name: "requestAccounts",
        provider: "ethereum",
        error: "Canceled",
        errorCode: 4001,
    });
    assert.equal((await finalizing).errorCode, 4001);
    assert.equal([...storage.keys()].some(key =>
        key.startsWith(approvalLeaseStoragePrefix)
    ), false);
});

test("manual finalization keeps revisions leased across worker restart", async () => {
    const now = 1_700_000_000_000;
    const storage = new Map;
    const pending = deferred();
    const first = makeHarness({
        dateNow: () => now,
        storage,
        native: message => isResponseRead(message)
            ? pending.promise
            : nativeAcknowledgement(message.id, message.revisions),
    });
    const acknowledged = await first.dispatch(manualSwitchIntent(), contentSender());
    const polling = first.dispatch({
        subject: "responseReady",
        id: acknowledged.id,
        workflowVersion: 3,
    }, {});
    await settle();
    const read = first.nativeMessages.find(({message}) =>
        isResponseRead(message)
    ).message;
    assert.deepEqual(read.revisions, {ethereum: 0, solana: 0});
    assert.equal(read.executionDeadline, now + 160_000);

    const restarted = makeHarness({
        dateNow: () => now,
        storage,
        native: () => assert.fail("a busy lease must not call native twice"),
    });
    restarted.startup();
    await settle();
    assert.equal(restarted.nativeMessages.length, 0);
    const blocked = await restarted.dispatch({
        subject: "disconnect",
        id: 107,
        provider: "ethereum",
        host: "wallet.example",
        configurationKey: "https://wallet.example",
        workflowVersion: 3,
    });
    assert.equal(blocked.errorCode, -32603);

    pending.resolve({
        id: acknowledged.id,
        name: "switchAccount",
        provider: "multiple",
        bodies: [],
        configurationToStore: [],
        providersToDisconnect: [],
    });
    await polling;
    assert.equal([...storage.keys()].some(key =>
        key.startsWith(approvalLeaseStoragePrefix)
    ), false);
});

test("expired approval leases are removed before provider mutation", async () => {
    const now = 1_700_000_200_000;
    const leaseKey = `${approvalLeaseStoragePrefix}wallet.example`;
    const storage = new Map([[leaseKey, {
        configurationKey: "wallet.example",
        issuedAt: now - 170_000,
        executionDeadline: now - 20_000,
        expiresAt: now - 10_000,
        revisions: {ethereum: 0, solana: 0},
        token: attempt,
        workflowVersion: 3,
    }]]);
    const harness = makeHarness({dateNow: () => now, storage});

    const disconnected = await harness.dispatch({
        subject: "disconnect",
        id: 99,
        provider: "ethereum",
        host: "wallet.example",
        configurationKey: "https://wallet.example",
        workflowVersion: 3,
    });

    assert.equal(disconnected.result, null);
    assert.equal(storage.has(leaseKey), false);
});

test("a backward clock change keeps a structurally live approval lease", async () => {
    const issuedAt = 1_700_000_000_000;
    const leaseKey = `${approvalLeaseStoragePrefix}wallet.example`;
    const storage = new Map([[leaseKey, {
        configurationKey: "wallet.example",
        issuedAt,
        executionDeadline: issuedAt + 150_000,
        expiresAt: issuedAt + 160_000,
        revisions: {ethereum: 0, solana: 0},
        token: attempt,
        workflowVersion: 3,
    }]]);
    const restarted = makeHarness({
        dateNow: () => issuedAt - 25_000,
        storage,
    });

    const blocked = await restarted.dispatch({
        subject: "disconnect",
        id: 101,
        provider: "ethereum",
        host: "wallet.example",
        configurationKey: "https://wallet.example",
        workflowVersion: 3,
    });

    assert.equal(blocked.errorCode, -32603);
    assert.equal(storage.has(leaseKey), true);
    assert.deepEqual(storage.get(leaseKey).revisions, {
        ethereum: 0,
        solana: 0,
    });
});

test("a malformed approval lease fails closed", async () => {
    const now = 1_700_000_000_000;
    const leaseKey = `${approvalLeaseStoragePrefix}wallet.example`;
    const storage = new Map([[leaseKey, {
        configurationKey: "wallet.example",
        issuedAt: now,
        executionDeadline: now + 151_000,
        expiresAt: now + 161_000,
        revisions: {ethereum: 0, solana: 0},
        token: attempt,
        workflowVersion: 3,
    }]]);
    const harness = makeHarness({dateNow: () => now, storage});

    const blocked = await harness.dispatch({
        subject: "disconnect",
        id: 102,
        provider: "ethereum",
        host: "wallet.example",
        configurationKey: "https://wallet.example",
        workflowVersion: 3,
    });

    assert.equal(blocked.errorCode, -32603);
    assert.equal(storage.has(leaseKey), true);
});

test("approval cleanup cannot remove a replacement lease", async () => {
    const now = 1_700_000_000_000;
    const storage = new Map;
    const replacementToken = "11111111111111111111111111111111";
    let leaseKey;
    const harness = makeHarness({
        dateNow: () => now,
        storage,
        native: () => {
            leaseKey = [...storage.keys()].find(key =>
                key.startsWith(approvalLeaseStoragePrefix)
            );
            const replacement = clone(storage.get(leaseKey));
            replacement.token = replacementToken;
            storage.set(leaseKey, replacement);
            return {status: "ok"};
        },
    });

    assert.deepEqual(clone(await harness.dispatch(
        approvalProxy(100),
        popupSender()
    )), {status: "ok"});
    assert.equal(storage.get(leaseKey).token, replacementToken);
});

test("approval cleanup serializes with replacement lease installation", async () => {
    let now = 1_700_000_000_000;
    const storage = new Map;
    let resolveFirst;
    let resolveSecond;
    const firstResponse = new Promise(resolve => { resolveFirst = resolve; });
    const secondResponse = new Promise(resolve => { resolveSecond = resolve; });
    let signalCleanupRead;
    const cleanupReadStarted = new Promise(resolve => {
        signalCleanupRead = resolve;
    });
    let releaseCleanupRead;
    const cleanupRead = new Promise(resolve => { releaseCleanupRead = resolve; });
    let leaseReads = 0;
    const harness = makeHarness({
        dateNow: () => now,
        storage,
        storageGet(keys, values) {
            const requested = Array.isArray(keys) ? keys : [keys];
            if (requested.some(key =>
                key.startsWith(approvalLeaseStoragePrefix)
            )) {
                leaseReads += 1;
                if (leaseReads === 2) {
                    signalCleanupRead();
                    return cleanupRead.then(() => values);
                }
            }
            return values;
        },
        native: message => {
            if (message.subject !== "approveRequest") { return undefined; }
            return message.id === 103 ? firstResponse : secondResponse;
        },
    });
    const first = harness.dispatch(approvalProxy(103), popupSender());
    await settle();
    now += 161_000;
    resolveFirst({status: "ok"});
    await cleanupReadStarted;

    const second = harness.dispatch(approvalProxy(104), popupSender());
    await settle();
    assert.equal(harness.nativeMessages.length, 1);

    releaseCleanupRead();
    assert.deepEqual(clone(await first), {status: "ok"});
    await settle();
    assert.equal(harness.nativeMessages.length, 2);
    const leaseEntry = [...storage.entries()].find(([key]) =>
        key.startsWith(approvalLeaseStoragePrefix)
    );
    assert.ok(leaseEntry);
    assert.equal(leaseEntry[1].issuedAt, now);

    resolveSecond({status: "ok"});
    assert.deepEqual(clone(await second), {status: "ok"});
    assert.equal(storage.has(leaseEntry[0]), false);
});

test("popup approval overwrites drifted revisions and preserves add-chain", async () => {
    const now = 1_700_000_000_000;
    const storage = new Map([["https://wallet.example", {
        latestConfigurations: [],
        revisions: {ethereum: 4, solana: 9},
        workflowVersion: 3,
    }]]);
    const harness = makeHarness({
        dateNow: () => now,
        storage,
        native: () => ({status: "ok"}),
    });

    assert.deepEqual(clone(await harness.dispatch(
        approvalProxy(93, {privateBrowsing: true}),
        popupSender()
    )), {status: "ok"});
    assert.deepEqual(harness.nativeMessages[0].message, {
        subject: "approveRequest",
        id: 93,
        requestToken,
        reviewToken,
        payload: {
            executionDeadline: now + 150_000,
            revisions: {ethereum: 4, solana: 9},
        },
        workflowVersion: 3,
        __bwPrivateBrowsing: true,
    });

    assert.deepEqual(clone(await harness.dispatch(
        approvalProxy(94),
        popupSender()
    )), {status: "ok"});
    assert.deepEqual(harness.nativeMessages[1].message.payload, {
        executionDeadline: now + 150_000,
        revisions: {ethereum: 4, solana: 9},
    });

    assert.deepEqual(clone(await harness.dispatch(
        approvalProxy(95, {payload: {selectedAccounts: [{
            walletId: "wallet",
            coin: "ethereum",
            address: "0x0000000000000000000000000000000000000001",
            derivationPath: "m/44'/60'/0'/0/0",
        }]}}),
        popupSender()
    )), {status: "ok"});
    assert.deepEqual(harness.nativeMessages[2].message.payload, {
        selectedAccounts: [{
            walletId: "wallet",
            coin: "ethereum",
            address: "0x0000000000000000000000000000000000000001",
            derivationPath: "m/44'/60'/0'/0/0",
        }],
        executionDeadline: now + 150_000,
        revisions: {ethereum: 4, solana: 9},
    });
});

test("malformed or untrusted popup approval proxy never reaches native", async () => {
    const invalidRequests = [
        [approvalProxy(95), undefined],
        [approvalProxy(95, {reviewToken: "invalid"}), popupSender()],
        [approvalProxy(95, {payload: {revisions: {ethereum: 0, solana: 0}}}), popupSender()],
        [approvalProxy(95, {privateBrowsing: "false"}), popupSender()],
        [{...approvalProxy(95), extra: true}, popupSender()],
        [approvalProxy(95, {host: "other.example"}), popupSender()],
        [approvalProxy(95, {payload: {password: "secret"}}), popupSender()],
        [approvalProxy(95, {payload: {selectedAccounts: [{
            walletId: "wallet",
            coin: "ethereum",
            address: "0x0000000000000000000000000000000000000001",
        }]}}), popupSender()],
    ];
    for (const [message, sender] of invalidRequests) {
        const harness = makeHarness({native: () => {
            throw new Error("must not reach native");
        }});
        assert.equal(await harness.dispatch(message, sender), undefined);
        assert.equal(harness.nativeMessages.length, 0);
    }
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
    assert.deepEqual(clone(second.revisions), {ethereum: 1, solana: 1});
    assert.equal(firstSettled, false);
    assert.deepEqual(harness.storage.get("https://wallet.example").revisions, {
        ethereum: 1,
        solana: 1,
    });

    releaseFirstQuery(matchingTabs);
    const firstResponse = await first;
    assert.equal(firstResponse.result, null);
    assert.deepEqual(clone(firstResponse.latestConfigurations), []);
    assert.deepEqual(clone(firstResponse.revisions), {ethereum: 1, solana: 0});
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
    assert.deepEqual(harness.timerDelays, [5000, 1000]);
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
    assert.deepEqual(harness.timerDelays, [1000, 5000]);
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
        native: message => isResponseRead(message) ? {
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

test("ordinary RPC returns failure after the long native-operation timeout", async () => {
    let resolveRPC;
    const harness = makeHarness({
        native: message => message.subject === "rpc"
            ? new Promise(resolve => { resolveRPC = resolve; })
            : undefined,
        scheduleTimeout(callback, delay) {
            if (delay === 180_000) { queueMicrotask(callback); }
            return delay;
        },
    });
    const response = await harness.dispatch({
        subject: "rpc",
        id: 45,
        chainId: "0x1",
        body: "{}",
        workflowVersion: 3,
    });

    assert.deepEqual(clone(response), {
        id: 45,
        error: "Failed to communicate with Big Wallet",
        errorCode: -32603,
    });
    assert.equal(harness.timerDelays.includes(180_000), true);
    resolveRPC({id: 45, result: "ok"});
    await settle();
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
