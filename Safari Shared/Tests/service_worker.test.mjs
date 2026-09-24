// ∅ 2026 lil org

import assert from "node:assert/strict";
import {webcrypto} from "node:crypto";
import {readFile} from "node:fs/promises";
import test from "node:test";
import vm from "node:vm";
import {nativeResult, nativeError} from "./test_helpers.mjs";

const [wireSource, workerSource, sharedManifestSource, macManifestSource] =
    await Promise.all([
    readFile(new URL("../Resources/bridge_wire.js", import.meta.url), "utf8"),
    readFile(new URL("../Resources/service_worker.js", import.meta.url), "utf8"),
    readFile(new URL("../Resources/manifest.json", import.meta.url), "utf8"),
    readFile(new URL("../../Safari macOS/Resources/manifest.json", import.meta.url), "utf8"),
    ]);
const requestToken = "123e4567-e89b-12d3-a456-426614174000";
const attempt = "00000001000000020000000300000004";
const admissionDeadline = 1_700_000_900_000;
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
function clone(value) {
    return typeof value === "undefined" ? undefined : JSON.parse(JSON.stringify(value));
}

function snapshot({ethereum = {address: "", chainId: "0x1"}, solana = null, revisions = {ethereum: 0, solana: 0}} = {}) {
    return {context: "a".repeat(64), revisions, ethereum, solana};
}

function ethereumState(address, chainId = "0x1") {
    return {address, chainId};
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
    executionNative,
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
    storageBeforeSet,
    workerPrivateBrowsing = false,
} = {}) {
    const retainedSwitches = new Map;
    const nativeMessages = [];
    const executionMessages = [];
    const recoveryMessages = [];
    const alarmGets = [];
    const alarmCreates = [];
    const alarmClears = [];
    const badgeTexts = [];
    const popupCalls = [];
    const runtimeMessages = [];
    const runtimeDeliveries = [];
    const tabMessages = [];
    const storageReads = [];
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
                if (message.subject === "getRecoveryRequests") {
                    recoveryMessages.push({application, message: clone(message)});
                    return Promise.resolve(recoveryNative
                        ? recoveryNative(message)
                        : {id: message.id, requests: [...retainedSwitches.values()]}).then(response => {
                            if (Array.isArray(response?.requests)) {
                                for (const request of response.requests) { retainedSwitches.set(request.id, request); }
                            }
                            return response;
                        });
                }
                if (["getExecutionStatus", "executeNativeApproval"].includes(message.subject)) {
                    assert.fail("Worker must not drive native execution");
                }
                if (message.subject === "maintainRequest") {
                    executionMessages.push({application, message: clone(message)});
                    if (executionNative) { return Promise.resolve(executionNative(message)); }
                    return Promise.resolve({id: message.id, pending: true});
                }
                nativeMessages.push({application, message: clone(message)});
                return Promise.resolve(message.subject === "acknowledgeResponse"
                    ? acknowledgeResponse(message)
                    : native ? native(message) : message.subject === "getLatestConfiguration"
                        ? {id: message.id, state: snapshot()} : undefined).then(response => {
                    if (response?.acknowledged === true || response?.missing === true) {
                        retainedSwitches.delete(message.id);
                    }
                    return response;
                });
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
                    storageReads.push(clone(keys));
                    const values = {};
                    for (const key of Array.isArray(keys) ? keys : [keys]) {
                        if (storage.has(key)) { values[key] = clone(storage.get(key)); }
                    }
                    return storageGet
                        ? Promise.resolve(storageGet(keys, values))
                        : Promise.resolve(values);
                },
                async set(values) {
                    await storageBeforeSet?.(clone(values));
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
        id: "extension-id",
        frameId: 0,
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
        executionMessages,
        recoveryMessages,
        popupCalls,
        runtimeMessages,
        runtimeDeliveries,
        storage,
        storageReads,
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
        async fireAlarm(name = recoveryAlarmName) {
            await alarmListener?.({name});
            await settle();
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
                const delivery = {handled: null, replies: []};
                runtimeDeliveries.push(delivery);
                delivery.handled = listener(request, sender, response => {
                    delivery.replies.push(clone(response));
                    resolve(response);
                });
                if (delivery.handled === false) { resolve(undefined); }
                else { assert.equal(delivery.handled, true); }
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
        authority: {context: "a".repeat(64), revisions: {ethereum: 0, solana: 0}},
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
        workflowVersion: 4,
        ...requestOverrides,
    };
}

function manualSwitchIntent(overrides = {}) {
    return {
        subject: "manualSwitchIntent",
        host: "wallet.example",
        configurationKey: "https://wallet.example",
        workflowVersion: 4,
        ...overrides,
    };
}

function manualSwitchDenial(id, state) {
    return {id, state, response: nativeError({
        id, name: "switchAccount", provider: "multiple",
        error: {code: 4100, message: "Authorization changed while the request was pending"},
    })};
}

function recoveryDescriptor(overrides = {}) {
    return {
        id: 31,
        configurationKey: "https://wallet.example",
        requestToken,
        manual: true,
        state: "pending",
        ...overrides,
    };
}

function contentSender(tab = {}) {
    return {
        id: "extension-id",
        frameId: 0,
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


function popupSender(overrides = {}) {
    return {id: "extension-id", url: "safari-web-extension://extension-id/popup.html", ...overrides};
}
function configurationRequest() {
    return {subject: "getLatestConfiguration", host: "wallet.example", configurationKey: "https://wallet.example", workflowVersion: 4};
}
function responseRequest(subject = "consumeResponse") {
    return {subject, id: 7, configurationKey: "https://wallet.example", requestToken, workflowVersion: 4};
}
function delivery(id = 7, state = snapshot(), result = []) {
    return {id, state, response: nativeResult({id, name: "requestAccounts", provider: "ethereum", result})};
}

test("bootstrap reads native and ignores all old browser authority", async () => {
    const state = snapshot({ethereum: ethereumState("0x01")});
    const harness = makeHarness({storage: new Map([["https://wallet.example", {bad: "cached grant"}],
        ["providerApprovalLease:wallet.example", {bad: "lease"}], ["nativeExecutionJobs", ["untrusted"]]]),
        native: message => ({id: message.id, state})});
    await settle();
    assert.deepEqual(clone(await harness.dispatch(configurationRequest())), {kind: "configuration", state});
    assert.deepEqual(harness.storageReads, []);
    assert.deepEqual(harness.storageWrites, []);
    assert.deepEqual(harness.storageRemovals, []);
    assert.equal(harness.nativeMessages.at(-1).message.subject, "getLatestConfiguration");
});

test("unreadable browser records cannot block configuration or account switching across origins and worker restarts", async () => {
    const origins = ["https://wallet.example", "https://other.example", "http://wallet.example"];
    const storage = new Map([
        [origins[0], "unreadable permission record"],
        [origins[1], {schemaVersion: Number.MAX_SAFE_INTEGER, grants: ["opaque"]}],
        [origins[2], null],
        ["wallet.example", {permissions: false}],
        ["other.example", [null]],
        ["providerApprovalLease:wallet.example", {token: "invalid"}],
        ["providerApprovalLease:other.example", "unreadable lease"],
        ["nativeExecutionJobs", {jobs: "unreadable"}],
    ]);
    const originalStorage = clone([...storage]);
    const states = new Map(origins.map((origin, index) => [origin, {
        ...snapshot({
            ethereum: index === 0 ? ethereumState(`0x${"1".repeat(40)}`) : ethereumState(""),
            revisions: {ethereum: index + 2, solana: index + 5},
        }),
        context: "abc"[index].repeat(64),
    }]));
    for (let restart = 0; restart < 2; restart += 1) {
        const harness = makeHarness({storage,
            storageGet: (keys, values) => {
                assert.deepEqual(Array.isArray(keys) ? keys : [keys], ["workflowUpdateRecoveryNeeded"]);
                return values;
            },
            native: message => {
                const state = states.get(message.configurationKey);
                assert.ok(state);
                if (message.subject === "getLatestConfiguration") { return {id: message.id, state}; }
                assert.equal(message.name, "switchAccount");
                assert.equal(message.host, new URL(message.configurationKey).host);
                assert.deepEqual(clone(message.authority), {context: state.context, revisions: state.revisions});
                assert.deepEqual(clone(message.body), {});
                return {id: message.id, admissionKind: "new", approvalRequired: true, requestToken, state};
            },
        });
        await settle();
        for (const [index, origin] of origins.entries()) {
            const identity = {configurationKey: origin, host: new URL(origin).host};
            const sender = contentSender({id: index + 9, url: `${origin}/dapp`});
            for (const configurationSender of [sender, popupSender()]) {
                assert.deepEqual(clone(await harness.dispatch({...configurationRequest(), ...identity}, configurationSender)),
                    {kind: "configuration", state: states.get(origin)});
            }
            const response = await harness.dispatch(manualSwitchIntent(identity), sender);
            assert.equal(response.subject, "manualSwitchAcknowledged");
            assert.equal(response.configurationKey, origin);
            assert.equal(response.approvalRequired, true);
            assert.deepEqual(clone(response.state), states.get(origin));
        }
        assert.equal(harness.nativeMessages.filter(({message}) => message.name === "switchAccount").length, origins.length);
        assert.equal(harness.popupCalls.length, origins.length);
        assert.deepEqual(harness.storageReads.flat().filter(key => key !== "workflowUpdateRecoveryNeeded"), []);
        assert.deepEqual(harness.storageWrites, []);
        assert.deepEqual(harness.storageRemovals, []);
        assert.deepEqual(clone([...storage]), originalStorage);
    }
});

test("every bootstrap reaches native, including same-origin callers sharing a worker", async () => {
    let profile = "a";
    const harness = makeHarness({native: message => ({id: message.id, state: {...snapshot(), context: profile.repeat(64)}})});
    const first = await harness.dispatch(configurationRequest());
    profile = "b";
    const second = await harness.dispatch(configurationRequest(), contentSender({id: 10}));
    assert.equal(first.state.context, "a".repeat(64));
    assert.equal(second.state.context, "b".repeat(64));
});

test("cold native unavailability never becomes an empty grant", async () => {
    for (const native of [() => undefined, () => { throw new Error("offline"); }, message => ({id: message.id, unavailable: true})]) {
        const harness = makeHarness({native});
        assert.equal((await harness.dispatch(configurationRequest())).kind, "configurationError");
    }
});

test("admission relays native authority preconditions and obtains native ACK", async () => {
    const state = snapshot();
    const harness = makeHarness({native: message => ({id: message.id, admissionKind: "new", approvalRequired: true, requestToken, state})});
    const response = await harness.dispatch(request());
    assert.deepEqual(clone(response), {id: 7, admissionKind: "new", approvalRequired: true, requestToken, state});
    const message = harness.nativeMessages.at(-1).message;
    assert.deepEqual(message.authority, request().authority);
    assert.equal(message.host, "wallet.example");
    assert.equal(message.configurationKey, "https://wallet.example");
    assert.equal(message.__bwPrivateBrowsing, false);
    assert.equal(Object.hasOwn(message, "revisions"), false);
    assert.equal(Object.hasOwn(message, "replayOnly"), false);
    assert.equal(harness.popupCalls.length, 1);
    assert.equal(harness.alarmCreates.length, 1);
    assert.deepEqual(harness.storageWrites, []);
});

test("native rejection wins over a cached account and carries a fresh snapshot", async () => {
    const state = snapshot({revisions: {ethereum: 9, solana: 0}});
    const harness = makeHarness({native: message => ({id: message.id, state, response: nativeError({
        id: message.id, name: message.name, provider: message.provider, error: {code: 4100, message: "Revoked"},
    })})});
    const response = await harness.dispatch(request(7, {message: {name: "signMessage", body: {address: "0x01"}}}));
    assert.equal(response.error.code, 4100);
    assert.deepEqual(clone(response.state), state);
    assert.deepEqual(harness.storageWrites, []);
});

test("malformed Solana trust options return a correlated error without native admission", async () => {
    const harness = makeHarness({native: () => assert.fail("must not reach native")});
    await settle();
    const alarmGets = harness.alarmGets.length;
    for (const name of ["connect", "signMessage", "signTransaction", "signAllTransactions", "signAndSendTransaction"]) {
        for (const onlyIfTrusted of [null, "true", 1, [], {}]) {
            const response = await harness.dispatch(request(7, {message: {
                name, provider: "solana", body: {publicKey: "", object: {params: {onlyIfTrusted}}},
            }}));
            assert.deepEqual(clone(response), {kind: "error", id: 7, provider: "solana", name,
                state: null, error: {code: -32602, message: "onlyIfTrusted must be a boolean"}});
        }
    }
    assert.equal(harness.nativeMessages.length, 0);
    assert.equal(harness.executionMessages.length, 0);
    assert.equal(harness.alarmGets.length, alarmGets);
});

test("Solana trust option validation accepts booleans and ignores missing or inherited values", async () => {
    const harness = makeHarness({native: message => ({id: message.id, admissionKind: "new", approvalRequired: false, requestToken, state: snapshot()})});
    const inherited = Object.create({onlyIfTrusted: "invalid inherited value"});
    for (const params of [undefined, {}, {onlyIfTrusted: undefined},
        {onlyIfTrusted: false}, {onlyIfTrusted: true}, inherited]) {
        const response = await harness.dispatch(request(7, {message: {
            name: "connect", provider: "solana", body: {publicKey: "", object: {params}},
        }}));
        assert.equal(response.requestToken, requestToken);
    }
    assert.equal(harness.nativeMessages.length, 6);
});

test("sender identity and strict native authority schema precede admission", async () => {
    const harness = makeHarness({native: () => assert.fail("must not reach native")});
    await settle();
    for (const changed of [{authority: undefined}, {authority: {context: "a".repeat(64), revisions: {ethereum: -1, solana: 0}}},
        {host: "forged.example"}, {configurationKey: "https://forged.example"}, {revisions: {ethereum: 0, solana: 0}},
        {enqueueAttempt: "bad"}, {workflowVersion: 3}]) {
        assert.equal(await harness.dispatch(request(7, changed)), undefined);
    }
    for (const sender of [null, {}, popupSender(), {...contentSender(), id: "foreign"},
        {...contentSender(), frameId: 1}, {...contentSender(), url: "data:text/html,hello"}]) {
        assert.equal(await harness.dispatch(request(), sender), undefined);
    }
    assert.equal(harness.nativeMessages.length, 0);
});

test("private browsing never admits or returns a grant", async () => {
    for (const localized of [undefined, "Localized Private Browsing explanation"]) {
        const harness = makeHarness({privateBrowsing: true,
            localizedMessages: {private_browsing_unsupported: localized},
            native: () => assert.fail("private native request")});
        const error = {code: 4200, message: localized ?? "Big Wallet requests are unavailable in Private Browsing."};
        assert.deepEqual(clone((await harness.dispatch(request())).error), error);
        assert.deepEqual(clone(await harness.dispatch(configurationRequest())), {kind: "configurationError", error});
        assert.equal(harness.nativeMessages.length, 0);
    }
});

test("completion relays an atomically committed native state and only acknowledges delivery", async () => {
    const state = snapshot({ethereum: ethereumState("0x01"), revisions: {ethereum: 1, solana: 0}});
    const harness = makeHarness({native: () => delivery(7, state, ["0x01"]),
        tabs: [{id: 3, url: "https://wallet.example/a"}, {id: 4, url: "https://other.example"},
            {id: 5, url: "https://wallet.example/b", incognito: true}]});
    const response = await harness.dispatch(responseRequest());
    assert.deepEqual(clone(response.state), state);
    assert.deepEqual(clone(response.result), ["0x01"]);
    assert.deepEqual(harness.nativeMessages.map(value => value.message.subject), ["prepareResponseDelivery", "acknowledgeResponse"]);
    assert.deepEqual(harness.storageWrites, []);
    assert.deepEqual(harness.tabMessages, [{id: 3, message: {
        subject: "configurationInvalidated", configurationKey: "https://wallet.example", workflowVersion: 4,
    }}]);
});

test("a lost acknowledgement retries delivery without reapplying a grant", async () => {
    let count = 0;
    const harness = makeHarness({native: () => delivery(), acknowledgeResponse: message => ++count === 1
        ? undefined : {id: message.id, acknowledged: true}});
    assert.equal(await harness.dispatch(responseRequest()), undefined);
    assert.equal((await harness.dispatch(responseRequest())).kind, "result");
    assert.equal(count, 2);
    assert.deepEqual(harness.storageWrites, []);
});

test("malformed or cross-correlated completions are never acknowledged", async () => {
    for (const response of [delivery(8), {...delivery(), state: {...snapshot(), context: "wrong"}},
        {...delivery(), response: {...delivery().response, mutation: null}}, nativeResult({id: 7, name: "requestAccounts", provider: "ethereum", result: []})]) {
        const harness = makeHarness({native: () => response});
        assert.equal(await harness.dispatch(responseRequest()), undefined);
        assert.equal(harness.nativeMessages.some(value => value.message.subject === "acknowledgeResponse"), false);
    }
});

test("status reads cannot directly deliver a signature", async () => {
    const harness = makeHarness({executionNative: () => delivery()});
    assert.equal(await harness.dispatch(responseRequest("getResponse")), undefined);
});

test("disconnect relays the exact idempotent native CAS and invalidates only on success", async () => {
    const state = snapshot({revisions: {ethereum: 2, solana: 0}});
    const harness = makeHarness({native: message => ({id: message.id, state, revoked: true})});
    const response = await harness.dispatch({subject: "disconnect", id: 7, provider: "ethereum", attempt,
        authority: request().authority, host: "wallet.example", configurationKey: "https://wallet.example", workflowVersion: 4});
    assert.equal(response.kind, "result");
    assert.equal(harness.nativeMessages.at(-1).message.attempt, attempt);
    assert.deepEqual(harness.nativeMessages.at(-1).message.authority, request().authority);
    assert.deepEqual(clone(response.state), state);
    assert.deepEqual(harness.storageWrites, []);
});

test("stale native disconnect returns current state without inventing authority", async () => {
    const state = snapshot({revisions: {ethereum: 2, solana: 0}});
    const harness = makeHarness({native: message => ({id: message.id, state, stale: true})});
    const response = await harness.dispatch({subject: "disconnect", id: 7, provider: "ethereum", attempt,
        authority: request().authority, host: "wallet.example", configurationKey: "https://wallet.example", workflowVersion: 4});
    assert.equal(response.error.code, 4100);
    assert.deepEqual(clone(response.state), state);
    assert.equal(harness.nativeMessages.length, 1);
});

test("popup completion does not accept browser revision or deadline authority", async () => {
    const harness = makeHarness({native: () => delivery()});
    const command = {...responseRequest("applyCompletedResponse"), host: "wallet.example"};
    assert.deepEqual(clone(await harness.dispatch(command, popupSender())), {applied: true});
    assert.equal(await harness.dispatch({...command, revisions: {ethereum: 0, solana: 0}}, popupSender()), undefined);
    assert.equal(await harness.dispatch({subject: "approveRequestWithCurrentRevisions"}, popupSender()), undefined);
});

test("startup and alarm recovery quietly maintain pending approved and manual requests without a live tab", async () => {
    for (const descriptor of [recoveryDescriptor({manual: false}), recoveryDescriptor({manual: false, state: "approved"}),
        recoveryDescriptor({state: "pending"}), recoveryDescriptor({state: "approved"})]) {
        const harness = makeHarness({tabs: [],
            recoveryNative: message => ({id: message.id, requests: [descriptor]}),
            executionNative: message => ({id: message.id, pending: true})});
        await settle();
        await harness.fireAlarm();
        assert.equal(harness.recoveryMessages[0].message.subject, "getRecoveryRequests");
        assert.deepEqual(harness.executionMessages.map(value => value.message.subject), ["maintainRequest", "maintainRequest"]);
        assert.deepEqual(harness.executionMessages.map(value => value.message.allowDelivery), [false, false]);
        assert.equal(harness.tabQueries(), 0);
        assert.equal(harness.tabMessages.length, 0);
        assert.deepEqual(harness.storageReads, []);
        assert.deepEqual(harness.storageWrites, []);
        assert.equal(await harness.runTimer(1000), false);
    }
});

test("live content polls permit exact native redelivery at most once every thirty seconds", async () => {
    let now = 1_700_000_000_000;
    const descriptor = recoveryDescriptor({id: 7, manual: false});
    const harness = makeHarness({tabs: [], dateNow: () => now,
        recoveryNative: message => ({id: message.id, requests: [descriptor]}),
        executionNative: message => ({id: message.id, pending: true}),
        native: message => ({id: message.id, pending: true})});
    await settle();
    assert.deepEqual(clone(await harness.dispatch(responseRequest("getResponse"))), {id: 7, pending: true});
    assert.deepEqual(harness.executionMessages.map(value => value.message.allowDelivery), [false, true]);
    assert.deepEqual(harness.executionMessages[1].message, {
        subject: "maintainRequest", id: descriptor.id, requestToken: descriptor.requestToken,
        configurationKey: descriptor.configurationKey, workflowVersion: 4,
        allowDelivery: true, __bwPrivateBrowsing: false,
    });
    now += 29_999;
    assert.deepEqual(clone(await harness.dispatch(responseRequest("getResponse"))), {id: 7, pending: true});
    assert.deepEqual(harness.executionMessages.map(value => value.message.allowDelivery), [false, true]);
    assert.deepEqual(harness.nativeMessages.map(value => value.message.subject), ["getResponse"]);
    now += 1;
    assert.deepEqual(clone(await harness.dispatch(responseRequest("getResponse"))), {id: 7, pending: true});
    assert.deepEqual(harness.executionMessages.map(value => value.message.allowDelivery), [false, true, true]);
    assert.deepEqual(harness.nativeMessages.map(value => value.message.subject), ["getResponse"]);
    assert.deepEqual(harness.tabMessages, []);
});

test("unauthorized and malformed status polls never enable native redelivery", async () => {
    for (const [command, sender] of [
        [responseRequest("getResponse"), popupSender()],
        [responseRequest("getResponse"), contentSender({url: "https://other.example"})],
        [responseRequest("getResponse"), contentSender({incognito: true})],
        [{...responseRequest("getResponse"), requestToken: "invalid"}, contentSender()],
        [{...responseRequest("getResponse"), allowDelivery: true}, contentSender()],
    ]) {
        const harness = makeHarness();
        await settle();
        assert.equal(await harness.dispatch(command, sender), undefined);
        assert.deepEqual(harness.executionMessages, []);
    }
});

test("idle recovery retains the alarm and no active polling timer", async () => {
    const harness = makeHarness();
    await settle();
    await harness.fireAlarm();
    assert.equal(harness.alarmCreates.length, 1);
    assert.deepEqual(harness.alarmClears, []);
    assert.equal(await harness.runTimer(1000), false);
});

test("manual switches bootstrap separately even when same-origin callers share the worker", async () => {
    let reads = 0;
    const harness = makeHarness({native: message => message.subject === "getLatestConfiguration"
        ? {id: message.id, state: {...snapshot(), context: (++reads === 1 ? "a" : "b").repeat(64)}}
        : {id: message.id, admissionKind: "new", approvalRequired: true, requestToken, state: {...snapshot(), ...message.authority}}});
    const values = await Promise.all([harness.dispatch(manualSwitchIntent()), harness.dispatch(manualSwitchIntent(), contentSender({id: 10}))]);
    assert.equal(reads, 2);
    assert.notEqual(values[0].state.context, values[1].state.context);
    const switches = harness.nativeMessages.filter(value => value.message.name === "switchAccount");
    assert.equal(switches.length, 2);
    assert.deepEqual(switches[0].message.body, {});
});

test("manual recovery consumes native completion without requiring the original tab", async () => {
    const descriptor = recoveryDescriptor({state: "completed"});
    const harness = makeHarness({tabs: [], recoveryNative: message => ({id: message.id, requests: [descriptor]}),
        native: message => ({id: message.id, state: snapshot(), response: nativeResult({id: message.id, name: "switchAccount", provider: "multiple", result: null})})});
    await settle();
    assert.deepEqual(harness.nativeMessages.map(value => value.message.subject), ["prepareResponseDelivery", "acknowledgeResponse"]);
});

test("native RPC relays preserve error data and reject uncorrelated results", async () => {
    const command = {subject: "rpc", id: 7, body: '{"method":"eth_call"}', chainId: "0x1", workflowVersion: 4};
    const error = {code: -32000, message: "revert", data: {reason: "0xab"}};
    const harness = makeHarness({native: () => ({id: 7, error})});
    assert.deepEqual(clone((await harness.dispatch(command)).error), error);
    const wrong = makeHarness({native: () => ({id: 8, result: "0x1"})});
    assert.equal((await wrong.dispatch(command)).kind, "error");
});

test("released pages get a reload error without reading old grants", async () => {
    const harness = makeHarness();
    const response = await harness.dispatch({subject: "getResponse", id: 7});
    assert.equal(response.provider, "multiple");
    assert.ok(response.bodies.every(value => /Reload/.test(value.error)));
    assert.deepEqual(harness.storageReads, []);
});

test("toolbar falls back to native app when the content probe fails", async () => {
    const harness = makeHarness({configuredPopup: false, sendTabMessage: () => undefined});
    harness.clickToolbar({id: 3, url: "https://wallet.example/dapp"});
    await settle();
    assert.equal(harness.nativeMessages.at(-1).message.subject, "openApp");
});

test("both manifests retain durable recovery alarm permission", () => {
    assert.equal(JSON.parse(sharedManifestSource).permissions.includes("alarms"), true);
    assert.equal(JSON.parse(macManifestSource).permissions.includes("alarms"), true);
});

test("all runtime routes enforce their sender matrix before effects", async () => {
    const harness = makeHarness();
    await settle();
    const commands = [
        [request(), ["content"]], [configurationRequest(), ["content", "popup"]],
        [responseRequest(), ["content"]], [responseRequest("getResponse"), ["content"]],
        [{...responseRequest("applyCompletedResponse"), host: "wallet.example"}, ["popup"]],
        [{subject: "responseReady", ids: [7], workflowVersion: 4}, ["popup"]],
        [{subject: "updatePendingRequestBadge", hasPendingRequests: true, workflowVersion: 4}, ["popup"]],
        [manualSwitchIntent(), ["content"]],
        ...["approveRequest", "executeNativeApproval", "getExecutionStatus", "maintainRequest",
            "prepareResponseDelivery", "requestActive", "constructor", "__proto__"].map(subject => [{subject, workflowVersion: 4}, []]),
    ];
    const senders = {content: contentSender(), popup: popupSender(),
        worker: {id: "extension-id", url: "safari-web-extension://extension-id/service_worker.js"}};
    for (const [command, allowed] of commands) {
        for (const [kind, sender] of Object.entries(senders)) {
            if (allowed.includes(kind)) { continue; }
            const count = harness.nativeMessages.length;
            assert.equal(await harness.dispatch(command, sender), undefined);
            assert.equal(harness.runtimeDeliveries.at(-1).handled, false);
            assert.equal(harness.nativeMessages.length, count);
        }
    }
});

test("native read timeout is bounded and does not initialize a cache", async () => {
    const harness = makeHarness({native: () => new Promise(() => {})});
    await settle();
    const pending = harness.dispatch(configurationRequest());
    await settle();
    assert.equal(await harness.runTimer(5000), true);
    assert.equal((await pending).kind, "configurationError");
    assert.deepEqual(harness.storageWrites, []);
});

test("durable recovery is armed before a native admission and survives its lost reply", async () => {
    const alarms = new Map;
    let admitted = false;
    const first = makeHarness({alarms, native: message => {
        assert.equal(alarms.has(recoveryAlarmName), true);
        admitted = true;
        return new Promise(() => {});
    }});
    await settle();
    const lost = first.dispatch(request());
    await settle();
    assert.equal(admitted, true);
    await first.runTimer(5000);
    assert.equal(await lost, undefined);
    const second = makeHarness({alarms,
        recoveryNative: message => ({id: message.id, requests: [recoveryDescriptor({manual: false, state: "completed"})]}),
        tabs: [{id: 9, url: "https://wallet.example"}]});
    await settle();
    assert.equal(second.alarmCreates.length, 0);
    assert.ok(second.tabMessages.some(value => value.message.subject === "responseReady"));
    assert.ok(second.tabMessages.some(value => value.message.subject === "configurationInvalidated"));
    assert.deepEqual(second.storageReads, []);
});

test("failed and malformed discovery retains recovery without executing or acknowledging", async () => {
    for (const recoveryNative of [() => {throw new Error("offline");}, () => undefined,
        message => ({id: message.id, requests: [{...recoveryDescriptor(), revisions: {ethereum: 0, solana: 0}}]}),
        message => ({id: message.id + 1, requests: [recoveryDescriptor()]})]) {
        const harness = makeHarness({recoveryNative});
        await settle();
        assert.equal(harness.alarms.has(recoveryAlarmName), true);
        assert.deepEqual(harness.alarmClears, []);
        assert.equal(harness.executionMessages.length, 0);
        assert.equal(harness.nativeMessages.length, 0);
    }
});

test("alarm creation failure prevents admission", async () => {
    const harness = makeHarness({createAlarm: () => {throw new Error("unavailable");},
        native: () => assert.fail("cannot admit without recovery")});
    assert.equal(await harness.dispatch(request()), undefined);
});

test("toolbar authenticates versioned probe before asking for a manual intent", async () => {
    const harness = makeHarness({configuredPopup: false, sendTabMessage: (_id, message) => {
        if (message.subject === "workflowProbe") { return {subject: "workflowProbe", nonce: message.nonce, workflowVersion: 4, buildVersion: packagedBuildVersion}; }
        return {subject: "manualSwitchAcknowledged", configurationKey: message.configurationKey,
            workflowVersion: 4, id: 7, approvalRequired: true, requestToken, state: snapshot()};
    }});
    harness.clickToolbar({id: 3, url: "https://wallet.example/path"});
    await settle();
    assert.deepEqual(harness.tabMessages.map(value => value.message.subject), ["workflowProbe", "manualSwitchIntent"]);
    assert.equal(harness.nativeMessages.at(-1).message.subject, "showApproval");
    assert.equal(harness.nativeMessages.some(value => value.message.subject === "openApp"), false);
});

test("toolbar mismatched builds nonces and workflows only open the native wallet", async () => {
    for (const change of [{buildVersion: previousBuildVersion}, {workflowVersion: 3}, {nonce: "0".repeat(32)}, {extra: true}]) {
        const harness = makeHarness({configuredPopup: false, sendTabMessage: (_id, message) => ({
            subject: "workflowProbe", nonce: message.nonce, workflowVersion: 4, buildVersion: packagedBuildVersion, ...change,
        })});
        harness.clickToolbar({id: 3, url: "https://wallet.example"});
        await settle();
        assert.equal(harness.nativeMessages.at(-1).message.subject, "openApp");
        assert.equal(harness.tabMessages.length, 1);
    }
});

test("toolbar private and unidentifiable tabs never ask content for an account", async () => {
    for (const tab of [{id: 3, url: "https://wallet.example", incognito: true}, {id: 3, url: "about:blank"}, {url: "https://wallet.example"}]) {
        const harness = makeHarness({configuredPopup: false});
        harness.clickToolbar(tab);
        await settle();
        assert.equal(harness.tabMessages.length, 0);
        assert.equal(harness.nativeMessages.at(-1).message.subject, "openApp");
        assert.equal(harness.nativeMessages.at(-1).message.__bwPrivateBrowsing, tab.incognito === true);
    }
});

test("RPC rejects malformed input and ambiguous native replies", async () => {
    for (const response of [undefined, {id: 8, result: true}, {id: 7, result: true, error: "also error"}, {id: 7}]) {
        const harness = makeHarness({native: () => response});
        const command = {subject: "rpc", id: 7, body: "{}", chainId: "0x1", workflowVersion: 4};
        assert.equal((await harness.dispatch(command)).kind, "error");
        const before = harness.nativeMessages.length;
        assert.equal((await harness.dispatch({...command, chainId: "0x01"})).kind, "error");
        assert.equal(harness.nativeMessages.length, before);
    }
});

test("a malformed tab query cannot prevent an acknowledged native result", async () => {
    const harness = makeHarness({native: () => delivery(), queryTabs: () => {throw new Error("closed browser");}});
    assert.equal((await harness.dispatch(responseRequest())).kind, "result");
});

test("manual-switch admission accepts the native coalesced handle bound to the bootstrapped origin context", async () => {
    const retainedID = 19;
    let attemptedID;
    const harness = makeHarness({native: message => {
        if (message.subject === "getLatestConfiguration") { return {id: message.id, state: snapshot()}; }
        attemptedID = message.id;
        return {id: retainedID, admissionKind: "coalesced", approvalRequired: true, requestToken, state: snapshot()};
    }});
    const response = await harness.dispatch(manualSwitchIntent());
    assert.notEqual(attemptedID, retainedID);
    assert.deepEqual(clone(response), {
        id: retainedID, approvalRequired: true, requestToken, state: snapshot(),
        configurationKey: "https://wallet.example", subject: "manualSwitchAcknowledged", workflowVersion: 4,
    });
});

test("a new manual switch drains the previous completion before admitting its own request", async () => {
    let retained;
    let admissions = 0;
    const attempted = [];
    const harness = makeHarness({configuredPopup: false,
        recoveryNative: message => ({id: message.id, requests: []}),
        acknowledgeResponse: message => {
            assert.equal(message.id, retained.id);
            retained = null;
            return {id: message.id, acknowledged: true};
        },
        native: message => {
            if (message.subject === "getLatestConfiguration") { return {id: message.id, state: snapshot()}; }
            if (message.subject === "prepareResponseDelivery") {
                return {id: message.id, state: snapshot(), response: nativeResult({
                    id: message.id, name: "switchAccount", provider: "multiple", result: null,
                })};
            }
            assert.equal(message.name, "switchAccount");
            attempted.push(message);
            const admissionKind = retained ? "coalesced" : "new";
            if (!retained) {
                admissions += 1;
                retained = {id: message.id, admissionKind: "new", approvalRequired: true, requestToken, state: snapshot()};
            }
            return {...retained, admissionKind};
        },
    });
    const first = await harness.dispatch(manualSwitchIntent());
    await settle();
    retained.approvalRequired = false;
    const second = await harness.dispatch(manualSwitchIntent());
    assert.equal(second.approvalRequired, true);
    assert.notEqual(second.id, first.id);
    assert.equal(admissions, 2);
    assert.equal(attempted.length, 3);
    assert.notEqual(attempted[1].enqueueAttempt, attempted[2].enqueueAttempt);
    assert.equal(attempted[1].admissionDeadline, attempted[2].admissionDeadline);
    assert.deepEqual(harness.nativeMessages.map(value => value.message.subject || value.message.name), [
        "getLatestConfiguration", "switchAccount", "getLatestConfiguration", "switchAccount",
        "prepareResponseDelivery", "acknowledgeResponse", "getLatestConfiguration", "switchAccount",
    ]);
});

test("a manual switch that completes its own admission does not open another request", async () => {
    let admissions = 0;
    const harness = makeHarness({native: message => {
        if (message.subject === "getLatestConfiguration") { return {id: message.id, state: snapshot()}; }
        admissions += 1;
        return {id: message.id, admissionKind: "new", approvalRequired: false, requestToken, state: snapshot()};
    }});
    assert.equal((await harness.dispatch(manualSwitchIntent())).approvalRequired, false);
    assert.equal(admissions, 1);
});

test("a coalesced manual completion is drained when separate intents generate the same numeric ID", async () => {
    let retained;
    let admissions = 0;
    const attempted = [];
    const harness = makeHarness({dateNow: () => 1_700_000_000_000,
        recoveryNative: message => ({id: message.id, requests: []}),
        acknowledgeResponse: message => {
            assert.equal(message.requestToken, retained.requestToken);
            retained = null;
            return {id: message.id, acknowledged: true};
        },
        native: message => {
            if (message.subject === "getLatestConfiguration") { return {id: message.id, state: snapshot()}; }
            if (message.subject === "prepareResponseDelivery") {
                return {id: message.id, state: snapshot(), response: nativeResult({
                    id: message.id, name: "switchAccount", provider: "multiple", result: null,
                })};
            }
            assert.equal(message.name, "switchAccount");
            attempted.push(message);
            const admissionKind = retained ? "coalesced" : "new";
            if (!retained) {
                admissions += 1;
                retained = {id: message.id, approvalRequired: true,
                    requestToken: admissions === 1 ? requestToken : "123e4567-e89b-12d3-a456-426614174001", state: snapshot()};
            }
            return {...retained, admissionKind};
        },
    });
    harness.read("Math.random = () => 0");
    const first = await harness.dispatch(manualSwitchIntent());
    retained.approvalRequired = false;
    const second = await harness.dispatch(manualSwitchIntent());
    assert.equal(attempted[1].id, first.id);
    assert.notEqual(attempted[1].enqueueAttempt, attempted[0].enqueueAttempt);
    assert.equal(second.approvalRequired, true);
    assert.notEqual(second.requestToken, first.requestToken);
    assert.equal(admissions, 2);
    assert.equal(attempted.length, 3);
    assert.equal(harness.nativeMessages.filter(value => value.message.subject === "acknowledgeResponse").length, 1);
});

test("manual new and replay acknowledgements require the submitted numeric ID", async () => {
    for (const admissionKind of ["new", "replay"]) {
        const harness = makeHarness({native: message => message.subject === "getLatestConfiguration"
            ? {id: message.id, state: snapshot()}
            : {id: message.id + 1, admissionKind, approvalRequired: true, requestToken, state: snapshot()}});
        assert.equal(await harness.dispatch(manualSwitchIntent()), undefined);
        assert.equal(harness.popupCalls.length, 0);
    }
});

test("manual-switch completion draining is bounded and requires an acknowledged result", async () => {
    for (const failure of ["unavailable", "acknowledgement", "coalesced"]) {
        let admissions = 0;
        const harness = makeHarness({
            acknowledgeResponse: message => failure === "acknowledgement"
                ? undefined : {id: message.id, acknowledged: true},
            native: message => {
                if (message.subject === "getLatestConfiguration") { return {id: message.id, state: snapshot()}; }
                if (message.subject === "prepareResponseDelivery") {
                    return failure !== "unavailable" ? {id: message.id, state: snapshot(), response: nativeResult({
                        id: message.id, name: "switchAccount", provider: "multiple", result: null,
                    })} : {id: message.id, unavailable: true};
                }
                admissions += 1;
                return {id: 19, admissionKind: "coalesced", approvalRequired: false, requestToken, state: snapshot()};
            },
        });
        assert.equal(await harness.dispatch(manualSwitchIntent()), undefined);
        assert.equal(admissions, failure === "coalesced" ? 2 : 1);
        assert.equal(harness.popupCalls.length, 0);
    }
});

test("coalesced manual handles reject malformed replies and other native origin contexts", async () => {
    for (const change of [{id: "19"}, {id: 1.5}, {id: Number.MAX_SAFE_INTEGER + 1},
        {requestToken: "malformed"}, {admissionKind: "new", approvalRequired: 1}, {extra: true},
        {configurationKey: "https://other.example"}, {state: {...snapshot(), context: "b".repeat(64)}},
        {state: {...snapshot(), revisions: {ethereum: -1, solana: 0}}}]) {
        const harness = makeHarness({native: message => message.subject === "getLatestConfiguration"
            ? {id: message.id, state: snapshot()}
            : {id: 19, admissionKind: "coalesced", approvalRequired: true, requestToken, state: snapshot(), ...change}});
        assert.equal(await harness.dispatch(manualSwitchIntent()), undefined);
        assert.equal(harness.popupCalls.length, 0);
    }
});

test("ordinary dapp admission still requires the exact request ID", async () => {
    const harness = makeHarness({native: () => ({id: 19, admissionKind: "coalesced", approvalRequired: true, requestToken, state: snapshot()})});
    assert.equal(await harness.dispatch(request(7)), undefined);
    assert.equal(harness.popupCalls.length, 0);
});

test("toolbar account selection retries one stale native authority snapshot", async () => {
    const initial = snapshot({revisions: {ethereum: 3, solana: 4}});
    const current = snapshot({revisions: {ethereum: 4, solana: 4}});
    const admissions = [];
    const harness = makeHarness({configuredPopup: false, dateNow: () => 1_700_000_000_000,
        native: message => {
            if (message.subject === "getLatestConfiguration") { return {id: message.id, state: initial}; }
            if (message.subject === "showApproval") { return {id: message.id, opened: true}; }
            assert.equal(message.name, "switchAccount");
            admissions.push(message);
            return admissions.length === 1 ? manualSwitchDenial(message.id, current)
                : {id: message.id, admissionKind: "new", approvalRequired: true, requestToken, state: current};
        },
        sendTabMessage: (_id, message) => message.subject === "workflowProbe"
            ? {subject: "workflowProbe", nonce: message.nonce, workflowVersion: 4, buildVersion: packagedBuildVersion}
            : harness.dispatch(manualSwitchIntent()),
    });
    await harness.read('handleToolbarClick({id: 3, url: "https://wallet.example/dapp"})');
    assert.equal(admissions.length, 2);
    assert.notEqual(admissions[0].id, admissions[1].id);
    assert.notEqual(admissions[0].enqueueAttempt, admissions[1].enqueueAttempt);
    assert.equal(admissions[0].admissionDeadline, admissionDeadline);
    assert.equal(admissions[1].admissionDeadline, admissionDeadline);
    assert.deepEqual(clone(admissions[1].authority), {context: current.context, revisions: current.revisions});
    assert.deepEqual(harness.nativeMessages.map(value => value.message.subject || value.message.name), [
        "getLatestConfiguration", "switchAccount", "switchAccount", "showApproval",
    ]);
});

test("toolbar waits for manual-switch retries and completion draining", async () => {
    const timers = new Map;
    let nextTimer = 0;
    const schedule = (callback, delay) => {
        const id = ++nextTimer;
        timers.set(id, {callback, delay});
        return id;
    };
    const harness = makeHarness({
        configuredPopup: false,
        scheduleTimeout: schedule,
        cancelTimeout: id => timers.delete(id),
        native: message => ({id: message.id, opened: true}),
        sendTabMessage: (_id, message) => message.subject === "workflowProbe"
            ? {...message, buildVersion: packagedBuildVersion}
            : new Promise(resolve => schedule(() => resolve({
                id: 41, requestToken, approvalRequired: true, state: snapshot(),
                configurationKey: message.configurationKey,
                subject: "manualSwitchAcknowledged", workflowVersion: 4,
            }), 37_000)),
    });
    const pending = harness.read('handleToolbarClick({id: 3, url: "https://wallet.example/dapp"})');
    await settle();
    const [id, timer] = [...timers].sort((left, right) => left[1].delay - right[1].delay)[0];
    timers.delete(id);
    timer.callback();
    await pending;
    assert.deepEqual(harness.nativeMessages.map(value => value.message.subject), ["showApproval"]);
    assert.equal(timers.size, 0);
});

test("manual-switch stale authority retries are bounded", async () => {
    let admissions = 0;
    const harness = makeHarness({native: message => {
        if (message.subject === "getLatestConfiguration") { return {id: message.id, state: snapshot()}; }
        admissions += 1;
        return manualSwitchDenial(message.id, snapshot({revisions: {ethereum: admissions, solana: 0}}));
    }});
    const response = await harness.dispatch(manualSwitchIntent());
    assert.equal(response.kind, "error");
    assert.equal(response.error.code, 4100);
    assert.equal(admissions, 2);
    assert.equal(harness.popupCalls.length, 0);
});

test("manual-switch admission never retries ambiguous or unrelated terminal replies", async () => {
    const initial = snapshot({revisions: {ethereum: 3, solana: 4}});
    const current = snapshot({revisions: {ethereum: 4, solana: 4}});
    const variants = [
        response => undefined,
        response => ({...response, extra: true}),
        response => ({...response, id: response.id + 1}),
        response => ({...response, response: {...response.response, id: response.id + 1}}),
        response => ({...response, state: {...current, context: "b".repeat(64)}}),
        response => ({...response, state: initial}),
        response => ({...response, state: snapshot({revisions: {ethereum: 4, solana: 3}})}),
        response => ({...response, response: {...response.response, name: "requestAccounts", provider: "ethereum"}}),
        response => ({...response, response: {...response.response, error: {code: 4001, message: "Canceled"}}}),
        response => response.response,
        () => { throw new Error("Native transport failed"); },
    ];
    for (const variant of variants) {
        let admissions = 0;
        const harness = makeHarness({native: message => {
            if (message.subject === "getLatestConfiguration") { return {id: message.id, state: initial}; }
            admissions += 1;
            return variant(manualSwitchDenial(message.id, current));
        }});
        await harness.dispatch(manualSwitchIntent());
        assert.equal(admissions, 1);
        assert.equal(harness.popupCalls.length, 0);
    }
});

test("manual-switch transport timeout does not create another admission", async () => {
    let admissions = 0;
    const harness = makeHarness({native: message => {
        if (message.subject === "getLatestConfiguration") { return {id: message.id, state: snapshot()}; }
        admissions += 1;
        return new Promise(() => {});
    }});
    const pending = harness.dispatch(manualSwitchIntent());
    await settle();
    assert.equal(await harness.runTimer(5000), true);
    assert.equal(await pending, undefined);
    assert.equal(admissions, 1);
});

test("manual-switch stale retries preserve the original deadline", async () => {
    let now = 1_700_000_000_000;
    let admissions = 0;
    const harness = makeHarness({dateNow: () => now, native: message => {
        if (message.subject === "getLatestConfiguration") { return {id: message.id, state: snapshot()}; }
        admissions += 1;
        now = message.admissionDeadline;
        return manualSwitchDenial(message.id, snapshot({revisions: {ethereum: 1, solana: 0}}));
    }});
    const response = await harness.dispatch(manualSwitchIntent());
    assert.equal(response.error.code, 4100);
    assert.equal(admissions, 1);
});

for (const sequence of [
    ["stale", "completed", "accepted"],
    ["completed", "stale", "accepted"],
    ["stale", "completed", "stale"],
    ["completed", "stale", "completed"],
]) {
    test(`manual-switch stale and completion retries have independent limits: ${sequence.join(", ")}`, async () => {
        let state = snapshot();
        const admissions = [];
        let drains = 0;
        const harness = makeHarness({dateNow: () => 1_700_000_000_000,
            recoveryNative: message => ({id: message.id, requests: []}),
            native: message => {
                if (message.subject === "getLatestConfiguration") { return {id: message.id, state}; }
                if (message.subject === "prepareResponseDelivery") {
                    drains += 1;
                    return {id: message.id, state, response: nativeResult({
                        id: message.id, name: "switchAccount", provider: "multiple", result: null,
                    })};
                }
                assert.equal(message.name, "switchAccount");
                admissions.push(message);
                const step = sequence[admissions.length - 1];
                assert.ok(step, "No fourth admission is allowed");
                if (step === "stale") {
                    state = snapshot({revisions: {ethereum: state.revisions.ethereum + 1, solana: 0}});
                    return manualSwitchDenial(message.id, state);
                }
                return {id: step === "completed" ? 19 : message.id,
                    admissionKind: step === "completed" ? "coalesced" : "new", approvalRequired: step === "accepted", requestToken, state};
            },
        });
        const response = await harness.dispatch(manualSwitchIntent());
        assert.equal(admissions.length, 3);
        assert.equal(new Set(admissions.map(value => value.id)).size, 3);
        assert.equal(new Set(admissions.map(value => value.enqueueAttempt)).size, 3);
        assert.ok(admissions.every(value => value.admissionDeadline === admissionDeadline));
        assert.equal(drains, 1);
        assert.equal(harness.nativeMessages.filter(value => value.message.subject === "acknowledgeResponse").length, 1);
        if (sequence[2] === "accepted") {
            assert.equal(response.approvalRequired, true);
            assert.equal(response.id, admissions[2].id);
            assert.equal(harness.popupCalls.length, 1);
        } else if (sequence[2] === "stale") {
            assert.equal(response.error.code, 4100);
        } else {
            assert.equal(response, undefined);
        }
    });
}

test("manual-switch completion refresh cannot extend an expired admission deadline", async () => {
    let now = 1_700_000_000_000;
    let reads = 0;
    let admissions = 0;
    const harness = makeHarness({dateNow: () => now, native: message => {
        if (message.subject === "getLatestConfiguration") {
            reads += 1;
            if (reads === 2) { now = admissionDeadline; }
            return {id: message.id, state: snapshot()};
        }
        if (message.subject === "prepareResponseDelivery") {
            return {id: message.id, state: snapshot(), response: nativeResult({
                id: message.id, name: "switchAccount", provider: "multiple", result: null,
            })};
        }
        admissions += 1;
        return {id: 19, admissionKind: "coalesced", approvalRequired: false, requestToken, state: snapshot()};
    }});
    assert.equal(await harness.dispatch(manualSwitchIntent()), undefined);
    assert.equal(admissions, 1);
    assert.equal(reads, 2);
});
