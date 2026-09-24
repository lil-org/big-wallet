// ∅ 2026 lil org

import assert from "node:assert/strict";
import {webcrypto} from "node:crypto";
import {readFile} from "node:fs/promises";
import test from "node:test";
import vm from "node:vm";
import {nativeError} from "./test_helpers.mjs";

const [wireSource, contentSource] = await Promise.all([
    readFile(new URL("../Resources/bridge_wire.js", import.meta.url), "utf8"),
    readFile(new URL("../Resources/content.js", import.meta.url), "utf8"),
]);
const requestToken = "123e4567-e89b-12d3-a456-426614174000";
const probeNonce = "00000001000000020000000300000004";
const workerSender = {
    id: "wallet-extension",
    url: "safari-web-extension://wallet",
};
const popupSender = {...workerSender, url: "safari-web-extension://wallet/popup.html"};
const packagedBuildVersion = wireSource.match(
    /const BUILD_VERSION = "([^"\n]+)";/
)?.[1];
assert.match(packagedBuildVersion, /^.+\+[0-9]+$/);

function wireSourceWithBuildVersion(buildVersion) {
    let replacements = 0;
    const result = wireSource.replace(
        /const BUILD_VERSION = "[^"\n]*";/g,
        () => {
            replacements += 1;
            return `const BUILD_VERSION = ${JSON.stringify(buildVersion)};`;
        }
    );
    assert.equal(replacements, 1);
    return result;
}

function clone(value) {
    return typeof value === "undefined" ? undefined : JSON.parse(JSON.stringify(value));
}

async function settle() {
    for (let index = 0; index < 80; index += 1) { await Promise.resolve(); }
}

function makeHarness({
    buildVersion = packagedBuildVersion,
    configurationResponse,
    failFirstInjection = false,
    sendMessage,
    url = "https://wallet.example/dapp",
} = {}) {
    const runtimeMessages = [];
    const runtimeDeliveries = [];
    const postedMessages = [];
    const timers = [];
    const injectedScripts = [];
    const pageListeners = [];
    const runtimeListeners = [];
    const focusListeners = [];
    const visibilityListeners = [];
    let injectionAttempts = 0;
    let clock = 1_700_000_000_000;
    let evaluatedWireSource = wireSourceWithBuildVersion(buildVersion);
    const attributes = object => {
        const values = new Map;
        object.setAttribute = (name, value) => values.set(name, String(value));
        object.getAttribute = name => values.get(name) ?? null;
        return object;
    };
    const document = {
        currentScript: null,
        doctype: {name: "html"},
        documentElement: {nodeName: "HTML"},
        visibilityState: "visible",
        createElement() { return attributes({textContent: ""}); },
        addEventListener(name, listener) {
            if (name === "visibilitychange") { visibilityListeners.push(listener); }
        },
    };
    const container = {
        children: [],
        insertBefore(script) {
            injectionAttempts += 1;
            if (failFirstInjection && injectionAttempts === 1) {
                throw new Error("injection failed");
            }
            injectedScripts.push(script.textContent);
            document.currentScript = script;
            new vm.Script(script.textContent).runInContext(context);
            document.currentScript = null;
        },
        removeChild() {},
    };
    document.head = container;
    const pageURL = new URL(url);
    const window = {
        document,
        location: {href: pageURL.href, pathname: pageURL.pathname},
        addEventListener(name, listener) {
            if (name === "message") { pageListeners.push(listener); }
            if (name === "focus") { focusListeners.push(listener); }
        },
        postMessage(message, target) {
            postedMessages.push({message: clone(message), target});
        },
    };
    const browser = {
        runtime: {
            id: "wallet-extension",
            getManifest() { return {version: packagedBuildVersion.split("+")[0]}; },
            getURL(path) { return `safari-web-extension://wallet/${path}`; },
            onMessage: {addListener(listener) { runtimeListeners.push(listener); }},
            sendMessage(message) {
                runtimeMessages.push(clone(message));
                if (message.subject === "getLatestConfiguration") {
                    return Promise.resolve(
                        typeof configurationResponse === "function"
                            ? configurationResponse(message)
                            : configurationResponse || {
                                kind: "configuration",
                                state: {context: "a".repeat(64), revisions: {ethereum: 0, solana: 0}, ethereum: {address: "", chainId: "0x1"}, solana: null},
                            }
                    );
                }
                return Promise.resolve(sendMessage?.(message));
            },
        },
    };
    class XMLHttpRequest {
        open() {}
        send() { this.responseText = "// provider fixture"; }
    }
    class FixedDate extends Date {
        constructor(...values) { super(values.length ? values[0] : clock); }
        static now() { return clock; }
    }
    const context = vm.createContext({
        browser,
        console: {error() {}},
        crypto: webcrypto,
        Date: FixedDate,
        document,
        Map,
        Promise,
        Set,
        URL,
        window,
        XMLHttpRequest,
        clearTimeout(timer) { if (timer) { timer.cancelled = true; } },
        setTimeout(callback, delay) {
            const timer = {callback, delay, due: clock + delay, cancelled: false};
            timers.push(timer);
            return timer;
        },
    });
    new vm.Script(evaluatedWireSource).runInContext(context);
    new vm.Script(contentSource).runInContext(context);
    return {
        context,
        injectedScripts,
        postedMessages,
        runtimeMessages,
        runtimeDeliveries,
        timerHistory: timers,
        generation: () => context.bigWalletProviderGeneration,
        injectionAttempts: () => injectionAttempts,
        listenerCounts: () => ({
            focus: focusListeners.length,
            page: pageListeners.length,
            runtime: runtimeListeners.length,
            visibility: visibilityListeners.length,
        }),
        pendingTimers: () => timers.filter(timer => !timer.cancelled).length,
        nextTimerDelay() {
            const timer = timers.filter(value => !value.cancelled)
                .sort((left, right) => left.due - right.due)[0];
            return timer ? Math.max(0, timer.due - clock) : null;
        },
        now: () => clock,
        dispatchPage(kind, message, generation = context.bigWalletProviderGeneration,
            observedRevision = context.bigWalletConfigurationState?.state.revisions[message.provider]) {
            for (const listener of pageListeners) {
                listener({
                    source: window,
                    data: {
                        direction: "big-wallet-provider-v1",
                        kind,
                        message,
                        observedRevision,
                        providerGeneration: generation,
                    },
                });
            }
        },
        dispatchRuntime(message, sender = workerSender) {
            return new Promise(resolve => {
                const delivery = {returns: [], responses: []};
                runtimeDeliveries.push(delivery);
                for (const listener of runtimeListeners) {
                    delivery.returns.push(listener(message, sender, response => {
                        delivery.responses.push(response);
                        resolve(response);
                    }));
                }
                if (!delivery.returns.includes(true)) { resolve(undefined); }
            });
        },
        reevaluate() {
            new vm.Script(evaluatedWireSource).runInContext(context);
            new vm.Script(contentSource).runInContext(context);
        },
        focus(event = {isTrusted: true}) {
            focusListeners.forEach(listener => listener(event));
        },
        async runTimer() {
            const timer = timers.filter(value => !value.cancelled)
                .sort((left, right) => left.due - right.due)[0];
            if (!timer) { return false; }
            timer.cancelled = true;
            clock = Math.max(clock, timer.due);
            timer.callback();
            await settle();
            return true;
        },
        advance(milliseconds) { clock += milliseconds; },
        show(event = {isTrusted: true}) {
            document.visibilityState = "visible";
            visibilityListeners.forEach(listener => listener(event));
        },
        setBuildVersion(value) {
            evaluatedWireSource = wireSourceWithBuildVersion(value);
        },
    };
}

function configurationState(revisions = {ethereum: 0, solana: 0}, context = "a".repeat(64)) {
    return {context, revisions, ethereum: {address: "", chainId: "0x1"}, solana: null};
}

function dappRequest(id = 7) {
    return {
        id,
        name: "requestAccounts",
        provider: "ethereum",
        body: {address: "", chainId: "0x1"},
    };
}

test("content rejects unauthorized runtime messages without effects or a response channel", async () => {
    const harness = makeHarness({sendMessage: message => message.subject === "message-to-wallet" ? {
        id: 7,
        requestToken,
        admissionKind: "new", approvalRequired: true,
        state: configurationState(),
    } : undefined});
    await settle();
    harness.dispatchPage("request", dappRequest());
    await settle();
    const messages = [
        {subject: "workflowProbe", nonce: probeNonce, workflowVersion: 4},
        {subject: "manualSwitchIntent", configurationKey: "https://wallet.example", workflowVersion: 4},
        {subject: "responseReady", id: 7, workflowVersion: 4},
        {
            subject: "configurationChanged",
            configurationKey: "https://wallet.example",
            workflowVersion: 4,
            state: {context: "a".repeat(64), revisions: {ethereum: 1, solana: 0}, ethereum: {address: "", chainId: "0x2"}, solana: null},
        },
    ];
    const deniedSenders = [
        null,
        {},
        {url: workerSender.url},
        {...workerSender, id: ""},
        {...workerSender, id: "foreign-extension"},
        {id: workerSender.id},
        {...workerSender, url: "safari-web-extension://wallet/unknown.html"},
        {...workerSender, url: `${workerSender.url}?spoof=1`},
        {...workerSender, tab: {id: 3}},
        {...popupSender, url: `${popupSender.url}#spoof`},
        {...workerSender, url: "data:text/html,hello"},
        {...workerSender, url: "https://wallet.example", tab: {id: 3}, frameId: 0},
        {...workerSender, url: "https://wallet.example", tab: {id: 3}, frameId: 1},
    ];
    const snapshot = () => clone({
        configuration: harness.context.bigWalletConfigurationState,
        generation: harness.generation(),
        postedMessages: harness.postedMessages,
        runtimeMessages: harness.runtimeMessages,
        requests: [...harness.context.bigWalletRequests.values()],
        timers: harness.timerHistory,
    });
    const before = snapshot();
    const denied = deniedSenders.flatMap(sender => messages.map(message => ({sender, message})));
    denied.push(...messages.slice(2).map(message => ({sender: popupSender, message})));
    denied.push(...[
        "rpc", "message-to-wallet", "getResponse", "getLatestConfiguration", "disconnect",
        "approveRequestWithCurrentRevisions", "applyCompletedResponse", "updatePendingRequestBadge",
        "pendingRequestAvailable", "unknown",
    ].map(subject => ({sender: workerSender, message: {subject, workflowVersion: 4}})));
    denied.push({sender: workerSender, message: null});
    for (const {sender, message} of denied) {
        assert.equal(await harness.dispatchRuntime(message, sender), undefined);
        assert.deepEqual(harness.runtimeDeliveries.at(-1), {returns: [false], responses: []});
    }
    await settle();
    assert.deepEqual(snapshot(), before);
});

test("content accepts popup probes and manual switch intents", async () => {
    const expected = {accepted: true};
    const harness = makeHarness({sendMessage: message =>
        message.subject === "manualSwitchIntent" ? expected : undefined});
    await settle();
    assert.deepEqual(clone(await harness.dispatchRuntime({
        subject: "workflowProbe", nonce: probeNonce, workflowVersion: 4,
    }, popupSender)), {
        buildVersion: packagedBuildVersion,
        nonce: probeNonce,
        subject: "workflowProbe",
        workflowVersion: 4,
    });
    assert.deepEqual(clone(await harness.dispatchRuntime({
        subject: "manualSwitchIntent", configurationKey: "https://wallet.example", workflowVersion: 4,
    }, popupSender)), expected);
    assert.equal(harness.runtimeMessages.filter(message => message.subject === "manualSwitchIntent").length, 1);
});

test("content reevaluation keeps one provider lifecycle and request bridge", async () => {
    const harness = makeHarness();
    await settle();
    const firstGeneration = harness.generation();
    assert.equal(typeof firstGeneration, "string");
    assert.equal(harness.runtimeMessages[0].subject, "getLatestConfiguration");
    assert.equal(harness.runtimeMessages[0].workflowVersion, 4);
    assert.deepEqual(harness.postedMessages[0].message.response.state.ethereum, {address: "", chainId: "0x1"});
    harness.reevaluate();
    await settle();
    assert.equal(harness.generation(), firstGeneration);
    assert.equal(harness.injectedScripts.length, 1);
    assert.equal(harness.runtimeMessages.filter(message => {
        return message.subject === "getLatestConfiguration";
    }).length, 1);
});

test("content scripts publish their captured per-build version", async () => {
    const harness = makeHarness();
    await settle();
    const runtimeMessageCount = harness.runtimeMessages.length;
    assert.deepEqual(clone(await harness.dispatchRuntime({
        nonce: probeNonce,
        subject: "workflowProbe",
        workflowVersion: 4,
    })), {
        buildVersion: packagedBuildVersion,
        nonce: probeNonce,
        subject: "workflowProbe",
        workflowVersion: 4,
    });
    assert.equal(harness.runtimeMessages.length, runtimeMessageCount);

    const nextBuildVersion = packagedBuildVersion.replace(
        /[0-9]+$/,
        value => String(Number(value) + 1)
    );
    harness.setBuildVersion(nextBuildVersion);
    harness.reevaluate();
    assert.deepEqual(clone(await harness.dispatchRuntime({
        nonce: probeNonce,
        subject: "workflowProbe",
        workflowVersion: 4,
    })), {
        buildVersion: packagedBuildVersion,
        nonce: probeNonce,
        subject: "workflowProbe",
        workflowVersion: 4,
    });

    for (const probe of [
        {subject: "workflowProbe", workflowVersion: 4},
        {nonce: "forged", subject: "workflowProbe", workflowVersion: 4},
        {nonce: probeNonce, subject: "workflowProbe", workflowVersion: 2},
        {
            nonce: probeNonce,
            subject: "workflowProbe",
            workflowVersion: 4,
            extra: true,
        },
    ]) {
        assert.equal(await harness.dispatchRuntime(probe), undefined);
    }
});

test("content reevaluation retries only a failed provider injection", async () => {
    const harness = makeHarness({failFirstInjection: true});
    await settle();
    assert.equal(harness.generation(), undefined);
    assert.equal(harness.injectionAttempts(), 1);
    assert.deepEqual(harness.listenerCounts(), {
        focus: 1,
        page: 1,
        runtime: 1,
        visibility: 1,
    });

    harness.reevaluate();
    await settle();
    assert.equal(typeof harness.generation(), "string");
    assert.equal(harness.injectionAttempts(), 2);
    assert.equal(harness.injectedScripts.length, 1);
    assert.deepEqual(harness.listenerCounts(), {
        focus: 1,
        page: 1,
        runtime: 1,
        visibility: 1,
    });
    assert.equal(harness.runtimeMessages.filter(message => {
        return message.subject === "getLatestConfiguration";
    }).length, 1);
});

test("three failed configuration reads emit one bootstrap failure", async () => {
    const harness = makeHarness({
        configurationResponse: {
            kind: "configurationError", error: {code: 4900, message: "Failed to communicate with Big Wallet"},
        },
    });
    await settle();
    await harness.runTimer();
    await harness.runTimer();

    const failures = harness.postedMessages.filter(value => {
        return value.message.response?.kind === "configurationError";
    });
    assert.deepEqual(failures, [{
        message: {
            direction: "big-wallet-content-v1",
            kind: "response",
            response: {kind: "configurationError", error: {
                code: 4900, message: "Failed to communicate with Big Wallet",
            }},
            providerGeneration: harness.generation(),
        },
        target: "*",
    }]);
    assert.equal(await harness.runTimer(), false);
});

test("unsupported bootstrap preserves its explanation without retries", async () => {
    const response = {kind: "configurationError", error: {code: 4200, message: "Localized Private Browsing explanation"}};
    const harness = makeHarness({configurationResponse: response});
    await settle();

    assert.deepEqual(harness.postedMessages, [{message: {
        direction: "big-wallet-content-v1", kind: "response", response,
        providerGeneration: harness.generation(),
    }, target: "*"}]);
    assert.equal(harness.runtimeMessages.length, 1);
    assert.equal(harness.context.bigWalletConfigurationState, undefined);
    assert.equal(harness.context.bigWalletFailedConfigurationGeneration, harness.generation());
    assert.equal(await harness.runTimer(), false);
});

test("unsupported warm refresh preserves the accepted snapshot without retries", async () => {
    let reads = 0;
    const state = configurationState({ethereum: 3, solana: 0});
    const harness = makeHarness({configurationResponse: () => ++reads === 1
        ? {kind: "configuration", state}
        : {kind: "configurationError", error: {code: 4200, message: "Unsupported"}}});
    await settle();
    harness.focus();
    await settle();

    assert.equal(reads, 2);
    assert.deepEqual(clone(harness.context.bigWalletConfigurationState.state), state);
    assert.equal(harness.postedMessages.some(value => value.message.response.kind === "configurationError"), false);
    assert.equal(await harness.runTimer(), false);
});

test("failed bootstrap retries on focus or visibility without reinjection", async () => {
    for (const trigger of ["focus", "show"]) {
        let nativeAvailable = false;
        let resolveRecovery;
        const harness = makeHarness({configurationResponse: () => nativeAvailable
            ? new Promise(resolve => { resolveRecovery = resolve; })
            : {kind: "configurationError", error: {code: 4900, message: "Failed to communicate with Big Wallet"}}});
        const generation = harness.generation();
        await settle();
        await harness.runTimer();
        await harness.runTimer();
        assert.equal(harness.runtimeMessages.length, 3);

        nativeAvailable = true;
        harness.reevaluate();
        harness[trigger]({isTrusted: false});
        assert.equal(harness.runtimeMessages.length, 3);
        harness[trigger]();
        harness.focus();
        harness.show();
        assert.equal(harness.runtimeMessages.length, 4);

        const configuration = {
            kind: "configuration",
            state: {context: "a".repeat(64), revisions: {ethereum: 0, solana: 0}, ethereum: {address: "", chainId: "0x1"}, solana: null},
        };
        resolveRecovery(configuration);
        await settle();
        assert.equal(harness.runtimeMessages.length, 5);
        resolveRecovery(configuration);
        await settle();
        assert.equal(harness.postedMessages.at(-1).message.kind, "response");
        assert.deepEqual(harness.postedMessages.at(-1).message.response, configuration);
        assert.equal(harness.generation(), generation);
        assert.equal(harness.injectionAttempts(), 1);
        assert.equal(await harness.runTimer(), false);
    }
});

test("a configuration broadcast recovers an exhausted bootstrap", async () => {
    const harness = makeHarness({configurationResponse: {kind: "configurationError", error: {code: 4900, message: "Failed to communicate with Big Wallet"}}});
    await settle();
    await harness.runTimer();
    await harness.runTimer();

    harness.context.bigWalletPublishConfiguration({context: "a".repeat(64), revisions: {ethereum: 0, solana: 0}, ethereum: {address: "", chainId: "0x1"}, solana: null}, "https://wallet.example", harness.generation());
    assert.equal(harness.postedMessages.at(-1).message.kind, "response");
    assert.equal(harness.postedMessages.at(-1).message.providerGeneration, harness.generation());
    assert.equal(harness.runtimeMessages.length, 3);
    assert.equal(harness.injectionAttempts(), 1);
});

test("an undefined configuration response follows the existing retry path", async () => {
    const harness = makeHarness({configurationResponse: () => undefined});
    await settle();
    assert.equal(harness.postedMessages.length, 0);
    assert.equal(harness.runtimeMessages.filter(message => {
        return message.subject === "getLatestConfiguration";
    }).length, 1);

    await harness.runTimer();
    await harness.runTimer();
    assert.equal(harness.runtimeMessages.filter(message => {
        return message.subject === "getLatestConfiguration";
    }).length, 3);
    assert.equal(harness.postedMessages.at(-1).message.response.kind, "configurationError");
});

test("malformed configuration responses follow the existing retry path", async () => {
    for (const response of [null, {}]) {
        const harness = makeHarness({configurationResponse: () => response});
        await settle();
        assert.equal(harness.postedMessages.length, 0);

        await harness.runTimer();
        await harness.runTimer();
        assert.equal(harness.runtimeMessages.filter(message => {
            return message.subject === "getLatestConfiguration";
        }).length, 3);
        assert.equal(harness.postedMessages.at(-1).message.response.kind, "configurationError");
    }
});

test("an invalidation hint rereads native rather than supplying accounts", async () => {
    let reads = 0;
    const harness = makeHarness({configurationResponse: () => ({kind: "configuration", state: configurationState({ethereum: reads++, solana: 0})})});
    await settle();
    await harness.dispatchRuntime({subject: "configurationInvalidated", configurationKey: "https://wallet.example", workflowVersion: 4});
    await settle();
    assert.equal(reads, 2);
    assert.equal(harness.postedMessages.at(-1).message.response.state.revisions.ethereum, 1);
    await harness.dispatchRuntime({subject: "configurationInvalidated", configurationKey: "https://wallet.example", workflowVersion: 4, state: configurationState()});
    assert.equal(reads, 2);
});

test("invalidation during bootstrap schedules a fresh native read", async () => {
    let resolveFirst;
    let reads = 0;
    const harness = makeHarness({configurationResponse: () => ++reads === 1 ? new Promise(resolve => {resolveFirst = resolve;})
        : {kind: "configuration", state: configurationState({ethereum: 1, solana: 0})}});
    await harness.dispatchRuntime({subject: "configurationInvalidated", configurationKey: "https://wallet.example", workflowVersion: 4});
    resolveFirst({kind: "configuration", state: configurationState()});
    await settle();
    assert.equal(reads, 2);
    assert.equal(harness.context.bigWalletConfigurationState.state.revisions.ethereum, 1);
});

test("focus and visibility coalesce into one follow-up native refresh", async () => {
    let reads = 0;
    let finish;
    const harness = makeHarness({configurationResponse: () => ++reads === 2
        ? new Promise(resolve => {finish = resolve;})
        : {kind: "configuration", state: configurationState()}});
    await settle();
    harness.focus(); harness.show(); harness.focus(); harness.show();
    assert.equal(reads, 2);
    finish({kind: "configuration", state: configurationState()});
    await settle();
    assert.equal(reads, 3);
    assert.equal(await harness.runTimer(), false);
});

test("foreground transition rereads native after an older refresh completes", async () => {
    let reads = 0;
    let finish;
    const connected = configurationState({ethereum: 1, solana: 0});
    connected.ethereum.address = "0x0000000000000000000000000000000000000001";
    let nativeState = connected;
    const harness = makeHarness({configurationResponse: () => ++reads === 2
        ? new Promise(resolve => {finish = resolve;})
        : {kind: "configuration", state: nativeState}});
    await settle();
    harness.focus();
    harness.context.document.visibilityState = "hidden";
    nativeState = configurationState({ethereum: 2, solana: 0});
    harness.show();
    assert.equal(reads, 2);

    finish({kind: "configuration", state: connected});
    await settle();

    assert.equal(reads, 3);
    assert.deepEqual(clone(harness.context.bigWalletConfigurationState.state), nativeState);
    assert.deepEqual(harness.postedMessages.at(-1).message.response.state, nativeState);
    assert.equal(await harness.runTimer(), false);
});

test("foreground transition also refreshes a pending initial snapshot", async () => {
    let reads = 0;
    let finish;
    const oldState = configurationState({ethereum: 1, solana: 0});
    oldState.ethereum.address = "0x0000000000000000000000000000000000000001";
    const currentState = configurationState({ethereum: 2, solana: 0});
    const harness = makeHarness({configurationResponse: () => ++reads === 1
        ? new Promise(resolve => {finish = resolve;})
        : {kind: "configuration", state: currentState}});
    harness.context.document.visibilityState = "hidden";
    harness.show();
    finish({kind: "configuration", state: oldState});
    await settle();

    assert.equal(reads, 2);
    assert.deepEqual(clone(harness.context.bigWalletConfigurationState.state), currentState);
});

test("focus and visibility reconcile configuration after a missed broadcast", async () => {
    let ethereumRevision = 0;
    const harness = makeHarness({configurationResponse: () => ({
        kind: "configuration",
        state: {context: "a".repeat(64), revisions: {ethereum: ethereumRevision, solana: 0}, ethereum: {address: "", chainId: "0x1"}, solana: null},
    })});
    await settle();

    ethereumRevision = 1;
    harness.focus();
    await settle();
    assert.deepEqual(harness.postedMessages.at(-1).message.response.state.revisions, {
        ethereum: 1,
        solana: 0,
    });

    ethereumRevision = 2;
    harness.show();
    await settle();
    assert.deepEqual(harness.postedMessages.at(-1).message.response.state.revisions, {
        ethereum: 2,
        solana: 0,
    });
    assert.equal(harness.runtimeMessages.filter(message => {
        return message.subject === "getLatestConfiguration";
    }).length, 3);
});

test("synthetic focus and visibility events do not reconcile configuration", async () => {
    const harness = makeHarness();
    await settle();

    harness.focus({isTrusted: false});
    harness.show({isTrusted: false});
    await settle();

    assert.equal(harness.runtimeMessages.filter(message => {
        return message.subject === "getLatestConfiguration";
    }).length, 1);
});

test("a replacement generation accepts its own lower revision baseline", async () => {
    let readCount = 0;
    const harness = makeHarness({configurationResponse() {
        readCount += 1;
        return {
            kind: "configuration",
            state: {context: "a".repeat(64), revisions: {ethereum: readCount === 1 ? 5 : 1, solana: 0}, ethereum: {address: "", chainId: "0x1"}, solana: null},
        };
    }});
    await settle();

    const replacementGeneration = "inpage:replacement";
    harness.context.bigWalletProviderGeneration = replacementGeneration;
    await harness.context.bigWalletLoadConfiguration(replacementGeneration, 0);
    assert.equal(readCount, 2);
    assert.deepEqual(harness.postedMessages.at(-1).message, {
        direction: "big-wallet-content-v1",
        kind: "response",
        response: {
            kind: "configuration",
            state: {context: "a".repeat(64), revisions: {ethereum: 1, solana: 0}, ethereum: {address: "", chainId: "0x1"}, solana: null},
        },
        id: harness.postedMessages.at(-1).message.id,
        providerGeneration: replacementGeneration,
    });

    await harness.context.bigWalletLoadConfiguration(replacementGeneration, 1);
    assert.equal(readCount, 3);
    assert.equal(harness.postedMessages.some(value => {
        return value.message.response?.kind === "configurationError";
    }), false);
});

test("a new native context replaces the provider generation before publishing accounts", async () => {
    let context = "a".repeat(64);
    const harness = makeHarness({configurationResponse: () => ({kind: "configuration", state: configurationState({ethereum: 0, solana: 0}, context)})});
    await settle();
    const previous = harness.generation();
    context = "b".repeat(64);
    harness.focus();
    await settle();
    assert.notEqual(harness.generation(), previous);
    assert.equal(harness.injectedScripts.length, 2);
    assert.equal(harness.postedMessages.at(-1).message.providerGeneration, harness.generation());
    assert.equal(harness.context.bigWalletConfigurationState.state.context, context);
});

test("stale terminal snapshots reach the provider with their original revisions", async () => {
    const address = "0x0000000000000000000000000000000000000001";
    const harness = makeHarness({sendMessage: message => {
        if (message.subject !== "message-to-wallet") { return undefined; }
        return {
            kind: "result",
            id: 7,
            name: "requestAccounts",
            provider: "ethereum",
            state: {context: "a".repeat(64), revisions: {ethereum: 1, solana: 0}, ethereum: {address: address, chainId: "0x1"}, solana: null},
            result: [address],
            approvalCommitted: false,
        };
    }});
    await settle();
    harness.context.bigWalletPublishConfiguration({context: "a".repeat(64), revisions: {ethereum: 2, solana: 0}, ethereum: {address: "", chainId: "0x1"}, solana: null}, "https://wallet.example", harness.generation());
    harness.dispatchPage("request", dappRequest(7));
    await settle();

    const terminal = harness.postedMessages.at(-1).message;
    assert.equal(terminal.response.id, 7);
    assert.deepEqual(terminal.response.state, {
        context: "a".repeat(64),
        revisions: {ethereum: 1, solana: 0},
        ethereum: {address, chainId: "0x1"}, solana: null,
    });
    assert.equal(terminal.response.configurationMatch, undefined);
    assert.equal(terminal.suppressProviderUpdate, undefined);
});

test("mixed provider revisions cross the content relay unchanged", async () => {
    const harness = makeHarness({configurationResponse: {
        kind: "configuration",
        state: {
            context: "a".repeat(64),
            revisions: {ethereum: 5, solana: 2},
            ethereum: {address: "", chainId: "0x2"},
            solana: null,
        },
    }});
    await settle();
    const state = {
        context: "a".repeat(64),
        revisions: {ethereum: 4, solana: 3},
        ethereum: {address: "", chainId: "0x1"},
        solana: {publicKey: "11111111111111111111111111111111"},
    };
    harness.context.bigWalletPublishConfiguration(state, "https://wallet.example", harness.generation());
    assert.deepEqual(harness.postedMessages.at(-1).message.response, {
        kind: "configuration", state,
    });
    assert.equal(harness.postedMessages.length, 2);
});

test("a malformed revisioned terminal fails closed", async () => {
    for (const delivery of ["immediate", "retained"]) {
        const response = {
            kind: "result",
            id: 7,
            name: "requestAccounts",
            provider: "ethereum",
            state: {context: "a".repeat(64), ethereum: {address: "0x0000000000000000000000000000000000000001", chainId: "0x1"}, solana: null},
            result: ["0x0000000000000000000000000000000000000001"],
            approvalCommitted: false,
        };
        const harness = makeHarness({sendMessage: message => {
            if (message.subject === "message-to-wallet") {
                return delivery === "immediate" ? response : {
                    id: 7,
                    requestToken,
                    admissionKind: "new", approvalRequired: false,
                    state: configurationState(),
                };
            }
            return message.subject === "getResponse" ? response : undefined;
        }});
        await settle();
        harness.dispatchPage("request", dappRequest(7));
        await settle();
        if (delivery === "retained") { await harness.runTimer(); }

        const terminal = harness.postedMessages.at(-1).message;
        assert.equal(terminal.response.id, 7);
        assert.equal(terminal.response.error?.code, -32603);
        assert.equal(terminal.response.result, undefined);
        assert.equal(terminal.response.state, null);
        assert.equal(terminal.response.configurationMatch, undefined);
        assert.equal(terminal.suppressProviderUpdate, undefined);
        assert.equal(harness.context.bigWalletRequests.size, 0);
        assert.equal(harness.pendingTimers(), 0);
    }
});

test("page-authored unknown provider requests never enter the relay", async () => {
    const harness = makeHarness();
    await settle();
    harness.dispatchPage("request", {
        id: 6,
        name: "switchAccount",
        provider: "unknown",
        body: {
            kind: "configuration",
            state: {context: "a".repeat(64), ethereum: {address: "", chainId: "0x1"}, solana: null},
        },
    });
    await settle();
    assert.equal(harness.runtimeMessages.some(message => {
        return message.subject === "message-to-wallet";
    }), false);
});

test("enqueues a trusted transient request with one generated attempt", async () => {
    const harness = makeHarness({sendMessage: message => message.subject ===
        "message-to-wallet" ? {
            id: 7,
            requestToken,
            admissionKind: "new", approvalRequired: true,
            state: configurationState(),
        } : undefined});
    await settle();
    harness.dispatchPage("request", dappRequest());
    await settle();
    const enqueue = harness.runtimeMessages.find(message => {
        return message.subject === "message-to-wallet";
    });
    assert.equal(enqueue.host, "wallet.example");
    assert.equal(enqueue.configurationKey, "https://wallet.example");
    assert.match(enqueue.enqueueAttempt, /^[0-9a-f]{32}$/);
    assert.equal(
        enqueue.admissionDeadline - harness.now(),
        15 * 60 * 1000
    );
    assert.equal(Number.isSafeInteger(enqueue.admissionDeadline), true);
    assert.deepEqual(enqueue.message, dappRequest());
});

test("a lost enqueue reply retries the identical attempt", async () => {
    let calls = 0;
    const harness = makeHarness({sendMessage: message => {
        if (message.subject !== "message-to-wallet") { return undefined; }
        calls += 1;
        return calls === 1 ? undefined : {
            id: 8,
            requestToken,
            admissionKind: "new", approvalRequired: true,
            state: configurationState(),
        };
    }});
    await settle();
    harness.dispatchPage("request", dappRequest(8));
    await settle();
    await harness.runTimer();
    const enqueues = harness.runtimeMessages.filter(message => {
        return message.subject === "message-to-wallet";
    });
    assert.equal(enqueues.length, 2);
    assert.deepEqual(enqueues[1], enqueues[0]);
    assert.equal(enqueues[0].admissionDeadline, enqueues[1].admissionDeadline);
});

test("replacement generations do not alias an old pending request ID", async () => {
    const harness = makeHarness({sendMessage: () => undefined});
    await settle();
    const originalGeneration = harness.generation();
    const request = dappRequest(23);
    harness.dispatchPage("request", request, originalGeneration);
    await settle();

    harness.reevaluate();
    harness.dispatchPage("request", request, originalGeneration);
    await settle();
    assert.equal(harness.runtimeMessages.filter(message => {
        return message.subject === "message-to-wallet" && message.message.id === 23;
    }).length, 1);

    const replacementGeneration =
        "inpage:replacement:00000001000000020000000300000004";
    harness.context.bigWalletProviderGeneration = replacementGeneration;
    await harness.context.bigWalletLoadConfiguration(replacementGeneration, 0);
    harness.dispatchPage("request", request, replacementGeneration);
    await settle();

    const enqueues = harness.runtimeMessages.filter(message => {
        return message.subject === "message-to-wallet" && message.message.id === 23;
    });
    assert.equal(enqueues.length, 2);
    assert.notEqual(enqueues[0].enqueueAttempt, enqueues[1].enqueueAttempt);
    assert.deepEqual(
        Array.from(
            harness.context.bigWalletRequests.values(),
            state => state.generation
        ).sort(),
        [originalGeneration, replacementGeneration].sort()
    );
});

test("an unacknowledged enqueue retries past its admission deadline", async () => {
    const harness = makeHarness({sendMessage: () => undefined});
    await settle();
    harness.dispatchPage("request", dappRequest(19));
    await settle();
    const first = harness.runtimeMessages.find(message => {
        return message.subject === "message-to-wallet";
    });

    harness.advance(15 * 60 * 1000);
    await harness.runTimer();
    await harness.runTimer();

    const enqueues = harness.runtimeMessages.filter(message => {
        return message.subject === "message-to-wallet";
    });
    assert.equal(enqueues.length, 3);
    assert.equal(harness.now() > first.admissionDeadline, true);
    assert.equal(enqueues.every(message => {
        return message.enqueueAttempt === first.enqueueAttempt &&
            message.admissionDeadline === first.admissionDeadline;
    }), true);
    assert.equal(harness.postedMessages.some(value => {
        return value.message.response?.id === 19;
    }), false);
});

test("enqueue recovery fails once at the retained-response horizon", async () => {
    const harness = makeHarness({sendMessage: () => undefined});
    await settle();
    harness.dispatchPage("request", dappRequest(20));
    await settle();

    harness.advance(75 * 60 * 1000 - 100);
    await harness.runTimer();
    assert.equal(harness.nextTimerDelay(), 100);
    await harness.runTimer();

    const responses = harness.postedMessages.filter(value => {
        return value.message.response?.id === 20;
    });
    assert.equal(responses.length, 1);
    assert.equal(responses[0].message.response.error?.code, -32603);
    assert.equal(harness.context.bigWalletRequests.size, 0);
    assert.equal(harness.pendingTimers(), 0);
    assert.equal(await harness.runTimer(), false);
});

test("a hung enqueue transport cannot deliver after horizon cleanup", async () => {
    let resolveEnqueue;
    let enqueueCalls = 0;
    const enqueue = new Promise(resolve => { resolveEnqueue = resolve; });
    const harness = makeHarness({sendMessage: message => {
        if (message.subject !== "message-to-wallet") { return undefined; }
        enqueueCalls += 1;
        return enqueueCalls === 1 ? undefined : enqueue;
    }});
    await settle();
    harness.dispatchPage("request", dappRequest(21));
    await settle();

    harness.advance(75 * 60 * 1000 - 100);
    await harness.runTimer();
    assert.equal(harness.nextTimerDelay(), 100);
    await harness.runTimer();
    resolveEnqueue({
        id: 21,
        requestToken,
        admissionKind: "new", approvalRequired: true,
        state: configurationState(),
    });
    await settle();

    assert.equal(harness.postedMessages.filter(value => {
        return value.message.response?.id === 21;
    }).length, 1);
    assert.equal(harness.context.bigWalletRequests.size, 0);
    assert.equal(harness.pendingTimers(), 0);
});

test("enqueue results arriving at the recovery deadline fail closed", async () => {
    const cases = [
        {
            id: 22,
            response: {
                id: 22,
                requestToken,
                admissionKind: "new", approvalRequired: true,
                state: configurationState(),
            },
        },
        {
            id: 23,
            response: {
                kind: "result",
                id: 23,
                name: "requestAccounts",
                provider: "ethereum",
                state: null,
                result: [],
                approvalCommitted: false,
            },
        },
    ];
    for (const value of cases) {
        let resolveEnqueue;
        const harness = makeHarness({sendMessage: message => {
            if (message.subject !== "message-to-wallet") { return undefined; }
            return new Promise(resolve => { resolveEnqueue = resolve; });
        }});
        await settle();
        harness.dispatchPage("request", dappRequest(value.id));
        await settle();

        harness.advance(75 * 60 * 1000);
        resolveEnqueue(value.response);
        await settle();

        const responses = harness.postedMessages.filter(entry => {
            return entry.message.response?.id === value.id;
        });
        assert.equal(responses.length, 1);
        assert.equal(responses[0].message.response.error?.code, -32603);
        assert.equal(harness.context.bigWalletRequests.size, 0);
        assert.equal(harness.pendingTimers(), 0);
    }
});

test("horizon cleanup releases all per-host request slots", async () => {
    const harness = makeHarness({sendMessage: () => undefined});
    await settle();
    for (let id = 40; id < 44; id += 1) {
        harness.dispatchPage("request", dappRequest(id));
    }
    await settle();

    harness.advance(75 * 60 * 1000);
    for (let index = 0; index < 4; index += 1) {
        assert.equal(await harness.runTimer(), true);
    }
    assert.equal(harness.context.bigWalletRequests.size, 0);
    assert.equal(harness.pendingTimers(), 0);

    harness.dispatchPage("request", dappRequest(44));
    await settle();
    assert.equal(harness.context.bigWalletRequests.size, 1);
    assert.equal(harness.runtimeMessages.some(message =>
        message.subject === "message-to-wallet" && message.message.id === 44
    ), true);
});

test("persistent failed response reads release acknowledged request slots", async () => {
    let resolveRead;
    const harness = makeHarness({sendMessage: message => {
        if (message.subject === "message-to-wallet") {
            return {
                id: message.message.id,
                requestToken,
                admissionKind: "new", approvalRequired: true,
                state: configurationState(),
            };
        }
        if (message.subject === "getResponse") {
            if (message.id === 41) { return {}; }
            if (message.id === 42) { throw new Error("unavailable"); }
            if (message.id === 43) {
                return new Promise(resolve => { resolveRead = resolve; });
            }
        }
        return undefined;
    }});
    await settle();
    harness.context.document.visibilityState = "hidden";
    for (let id = 40; id < 44; id += 1) {
        harness.dispatchPage("request", dappRequest(id));
    }
    await settle();

    const startedAt = harness.now();
    while (harness.context.bigWalletRequests.size > 0) {
        assert.equal(await harness.runTimer(), true);
        assert.ok(harness.now() - startedAt <= 61 * 60 * 1000);
    }
    assert.ok(harness.now() - startedAt >= 60 * 60 * 1000);
    resolveRead({
        kind: "result",
        id: 43,
        name: "requestAccounts",
        provider: "ethereum",
        state: null,
        result: [],
        approvalCommitted: false,
    });
    await settle();

    for (let id = 40; id < 44; id += 1) {
        const responses = harness.postedMessages.filter(value => {
            return value.message.response?.id === id;
        });
        assert.equal(responses.length, 1);
        assert.equal(responses[0].message.response.error?.code, -32603);
    }
    assert.equal(harness.context.bigWalletRequests.size, 0);
    assert.equal(harness.pendingTimers(), 0);

    harness.dispatchPage("request", dappRequest(44));
    await settle();
    assert.equal(harness.context.bigWalletRequests.size, 1);
    assert.equal(harness.runtimeMessages.some(message =>
        message.subject === "message-to-wallet" && message.message.id === 44
    ), true);
});

test("new content attempts fail without allocation at the per-host limit", async () => {
    const harness = makeHarness({sendMessage: () => undefined});
    await settle();
    for (let id = 30; id < 34; id += 1) {
        harness.dispatchPage("request", dappRequest(id));
    }
    await settle();

    assert.equal(harness.context.bigWalletRequests.size, 4);
    assert.equal(harness.pendingTimers(), 4);
    assert.deepEqual(harness.runtimeMessages.filter(message => {
        return message.subject === "message-to-wallet";
    }).map(message => message.message.id), [30, 31, 32, 33]);

    harness.dispatchPage("request", dappRequest(34));
    await settle();
    assert.equal(harness.context.bigWalletRequests.size, 4);
    assert.equal(harness.pendingTimers(), 4);
    assert.equal(harness.runtimeMessages.some(message => {
        return message.subject === "message-to-wallet" && message.message.id === 34;
    }), false);
    assert.deepEqual(harness.postedMessages.at(-1).message.response, {
        kind: "error",
        id: 34,
        name: "requestAccounts",
        provider: "ethereum",
        state: null,
        error: {code: -32603, message: "Failed to communicate with Big Wallet"},
    });

    harness.dispatchPage("request", dappRequest(30));
    await settle();
    assert.equal(harness.runtimeMessages.filter(message => {
        return message.subject === "message-to-wallet" && message.message.id === 30;
    }).length, 1);
    assert.equal(harness.postedMessages.some(value => {
        return value.message.response?.id === 30;
    }), false);

    const first = harness.runtimeMessages.find(message => {
        return message.subject === "message-to-wallet" && message.message.id === 30;
    });
    harness.advance(15 * 60 * 1000 + 1);
    await harness.runTimer();
    const retries = harness.runtimeMessages.filter(message => {
        return message.subject === "message-to-wallet" && message.message.id === 30;
    });
    assert.equal(retries.length, 2);
    assert.equal(harness.now() > first.admissionDeadline, true);
    assert.equal(retries[1].enqueueAttempt, first.enqueueAttempt);
    assert.equal(retries[1].admissionDeadline, first.admissionDeadline);
});

test("reads and delivers one retained response", async () => {
    const harness = makeHarness({sendMessage: message => {
        if (message.subject === "message-to-wallet") {
            return {
                id: 9,
                requestToken,
                admissionKind: "new", approvalRequired: false,
                state: configurationState(),
            };
        }
        if (message.subject === "getResponse") {
            return {
                kind: "result",
                id: 9,
                name: "requestAccounts",
                provider: "ethereum",
                state: null,
                result: [],
                approvalCommitted: false,
            };
        }
        return undefined;
    }});
    await settle();
    harness.dispatchPage("request", dappRequest(9));
    await settle();
    await harness.runTimer();
    const delivery = harness.postedMessages.find(value => {
        return value.message.response?.id === 9;
    });
    assert.equal(delivery.message.kind, "response");
    assert.deepEqual(harness.runtimeMessages.map(message => message.subject), [
        "getLatestConfiguration", "message-to-wallet", "getResponse",
    ]);
    assert.equal("revisions" in harness.runtimeMessages[2], false);
});

test("response polling allows twenty seconds for native status preparation and acknowledgement", async () => {
    const result = {
        kind: "result", id: 7, name: "requestAccounts", provider: "ethereum",
        state: null, result: [], approvalCommitted: true,
    };
    const harness = makeHarness({sendMessage: message => {
        if (message.subject === "message-to-wallet") {
            return {id: 7, requestToken, admissionKind: "new", approvalRequired: false, state: configurationState()};
        }
        if (message.subject === "getResponse") {
            return new Promise(resolve => harness.context.setTimeout(() => resolve(result), 16_000));
        }
    }});
    await settle();
    harness.dispatchPage("request", dappRequest());
    await settle();
    await harness.runTimer();
    assert.deepEqual(harness.postedMessages.at(-1).message.response, result);
    assert.equal(harness.runtimeMessages.filter(message => message.subject === "getResponse").length, 1);
    assert.equal(harness.context.bigWalletRequests.size, 0);
    assert.equal(harness.pendingTimers(), 0);
});

test("response polling times out at twenty seconds and ignores a late reply before retrying", async () => {
    const result = {
        kind: "result", id: 7, name: "requestAccounts", provider: "ethereum",
        state: null, result: [], approvalCommitted: true,
    };
    let resolveFirstRead;
    let reads = 0;
    const harness = makeHarness({sendMessage: message => {
        if (message.subject === "message-to-wallet") {
            return {id: 7, requestToken, admissionKind: "new", approvalRequired: false, state: configurationState()};
        }
        if (message.subject === "getResponse") {
            reads += 1;
            return reads === 1 ? new Promise(resolve => { resolveFirstRead = resolve; }) : result;
        }
    }});
    await settle();
    harness.dispatchPage("request", dappRequest());
    await settle();
    const startedAt = harness.now();
    assert.equal(harness.nextTimerDelay(), 20_000);
    harness.advance(19_999);
    assert.equal(harness.nextTimerDelay(), 1);
    assert.equal(harness.postedMessages.some(value => value.message.response?.id === 7), false);

    await harness.runTimer();
    assert.equal(harness.now() - startedAt, 20_000);
    assert.equal(harness.nextTimerDelay(), 1000);
    assert.equal(harness.context.bigWalletRequests.size, 1);
    resolveFirstRead(result);
    await settle();
    assert.equal(harness.postedMessages.some(value => value.message.response?.id === 7), false);

    await harness.runTimer();
    assert.equal(reads, 2);
    assert.deepEqual(harness.postedMessages.at(-1).message.response, result);
    assert.equal(harness.context.bigWalletRequests.size, 0);
    assert.equal(harness.pendingTimers(), 0);
});

test("an evicted retained response fails immediately", async () => {
    const harness = makeHarness({sendMessage: message => {
        if (message.subject === "message-to-wallet") {
            return {
                id: 18,
                requestToken,
                admissionKind: "new", approvalRequired: false,
                state: configurationState(),
            };
        }
        if (message.subject === "getResponse") {
            return {id: 18, missing: true};
        }
        return undefined;
    }});
    await settle();
    harness.dispatchPage("request", dappRequest(18));
    await settle();
    await harness.runTimer();

    const response = harness.postedMessages.at(-1).message.response;
    assert.equal(response.id, 18);
    assert.equal(response.error?.code, -32603);
    assert.equal(await harness.runTimer(), false);
});

test("response-ready hints wake a waiting request", async () => {
    let ready = false;
    const harness = makeHarness({sendMessage: message => {
        if (message.subject === "message-to-wallet") {
            return {
                id: 10,
                requestToken,
                admissionKind: "new", approvalRequired: true,
                state: configurationState(),
            };
        }
        if (message.subject === "getResponse" && ready) {
            return {
                kind: "result",
                id: 10,
                name: "requestAccounts",
                provider: "ethereum",
                state: null,
                result: [],
                approvalCommitted: false,
            };
        }
        return undefined;
    }});
    await settle();
    harness.dispatchPage("request", dappRequest(10));
    await settle();
    ready = true;
    await harness.dispatchRuntime({
        subject: "responseReady",
        id: 10,
        workflowVersion: 4,
    });
    await harness.runTimer();
    assert.equal(harness.postedMessages.some(value => {
        return value.message.response?.id === 10;
    }), true);
});

test("response-ready hints rerun an active response read", async () => {
    let resolveFirstRead;
    let resolveSecondRead;
    let reads = 0;
    const harness = makeHarness({sendMessage: message => {
        if (message.subject === "message-to-wallet") {
            return {
                id: 11,
                requestToken,
                admissionKind: "new", approvalRequired: true,
                state: configurationState(),
            };
        }
        if (message.subject === "getResponse") {
            reads += 1;
            if (reads === 1) {
                return new Promise(resolve => { resolveFirstRead = resolve; });
            }
            if (reads === 2) {
                return new Promise(resolve => { resolveSecondRead = resolve; });
            }
        }
        return undefined;
    }});
    await settle();
    harness.dispatchPage("request", dappRequest(11));
    await settle();
    await harness.runTimer();
    await harness.dispatchRuntime({
        subject: "responseReady",
        id: 11,
        workflowVersion: 4,
    });

    resolveFirstRead();
    await settle();
    assert.equal(reads, 2);
    assert.equal(harness.pendingTimers(), 1);
    resolveSecondRead({
        kind: "result", id: 11, name: "requestAccounts", provider: "ethereum",
        state: null, result: [], approvalCommitted: false,
    });
    await settle();
    assert.equal(harness.postedMessages.some(value => {
        return value.message.response?.id === 11;
    }), true);
    assert.equal(await harness.runTimer(), false);
});

test("late enqueue acknowledgement preserves native-owned work past the recovery horizon", async () => {
    let ready = false;
    let enqueueCalls = 0;
    const harness = makeHarness({sendMessage: message => {
        if (message.subject === "message-to-wallet") {
            enqueueCalls += 1;
            if (enqueueCalls === 1) { return undefined; }
            return {
                id: 15,
                requestToken,
                admissionKind: "new", approvalRequired: true,
                state: configurationState(),
            };
        }
        if (message.subject === "getResponse") {
            return ready ? {
                kind: "result", id: 15, name: "requestAccounts", provider: "ethereum",
                state: null, result: [], approvalCommitted: false,
            } : {id: 15, pending: true};
        }
        return undefined;
    }});
    await settle();
    harness.dispatchPage("request", dappRequest(15));
    await settle();
    harness.advance(15 * 60 * 1000 + 1);
    await harness.runTimer();
    assert.equal(enqueueCalls, 2);
    harness.advance(60 * 60 * 1000);
    await harness.runTimer();
    assert.equal(harness.postedMessages.some(value => {
        return value.message.response?.id === 15;
    }), false);
    assert.equal(harness.runtimeMessages.filter(message => {
        return message.subject === "getResponse";
    }).length, 1);
    ready = true;
    await harness.runTimer();
    assert.equal(harness.postedMessages.at(-1).message.response.id, 15);
    assert.equal(harness.postedMessages.at(-1).message.response.error?.code, undefined);
    assert.equal(harness.context.bigWalletRequests.size, 0);
});

test("native results survive suspension past the recovery horizon", async () => {
    for (const delivery of ["ready", "inFlight", "timeoutFirst"]) {
        let resolveRead;
        let reads = 0;
        const response = {
            kind: "result",
            id: 17,
            name: "signTransaction",
            provider: "ethereum",
            state: null,
            result: ["0xtransactionHash"],
            approvalCommitted: false,
        };
        const harness = makeHarness({sendMessage: message => {
            if (message.subject === "message-to-wallet") {
                return {
                    id: 17, requestToken, admissionKind: "new", approvalRequired: true,
                    state: configurationState(),
                };
            }
            if (message.subject !== "getResponse") { return undefined; }
            reads += 1;
            return delivery !== "ready" && reads === 1
                ? new Promise(resolve => { resolveRead = resolve; })
                : response;
        }});
        await settle();
        harness.dispatchPage("request", {...dappRequest(17), name: "signTransaction"});
        await settle();
        if (delivery !== "ready") { await harness.runTimer(); }
        harness.advance(76 * 60 * 1000);
        if (delivery === "timeoutFirst") {
            await harness.runTimer();
            assert.equal(harness.context.bigWalletRequests.size, 1);
        }
        if (delivery !== "ready") {
            resolveRead(response);
            await settle();
        } else {
            await harness.runTimer();
        }
        if (delivery === "timeoutFirst") { await harness.runTimer(); }
        assert.deepEqual(harness.postedMessages.at(-1).message.response, response);
        assert.equal(harness.context.bigWalletRequests.size, 0);
        assert.equal(harness.pendingTimers(), 0);
    }
});

test("native pending replies reset the communication failure budget", async () => {
    let pending = false;
    const harness = makeHarness({sendMessage: message => {
        if (message.subject === "message-to-wallet") {
            return {
                id: 18, requestToken, admissionKind: "new", approvalRequired: true,
                state: configurationState(),
            };
        }
        return pending ? {id: 18, pending: true} : undefined;
    }});
    await settle();
    harness.context.document.visibilityState = "hidden";
    harness.dispatchPage("request", dappRequest(18));
    await settle();

    async function pollFor(milliseconds) {
        const until = harness.now() + milliseconds;
        while (harness.now() < until && harness.context.bigWalletRequests.size > 0) {
            assert.equal(await harness.runTimer(), true);
        }
    }

    await pollFor(59 * 60 * 1000);
    pending = true;
    await harness.runTimer();
    assert.equal(harness.context.bigWalletRequests.size, 1);

    pending = false;
    await pollFor(59 * 60 * 1000);
    assert.equal(harness.context.bigWalletRequests.size, 1);
    await pollFor(2 * 60 * 1000);
    assert.equal(harness.postedMessages.at(-1).message.response.error?.code, -32603);
    assert.equal(harness.context.bigWalletRequests.size, 0);
    assert.equal(harness.pendingTimers(), 0);
});

test("transport and delivery failures share one budget while terminal success still completes", async () => {
    for (const succeeds of [false, true]) {
        let response;
        const harness = makeHarness({sendMessage: message => {
            if (message.subject === "message-to-wallet") {
                return {id: 7, requestToken, admissionKind: "new", approvalRequired: true, state: configurationState()};
            }
            if (message.subject === "getResponse") { return response; }
        }});
        await settle();
        harness.context.document.visibilityState = "hidden";
        harness.dispatchPage("request", dappRequest());
        await settle();
        const startedAt = harness.now();
        while (harness.now() - startedAt < 59 * 60 * 1000) {
            assert.equal(await harness.runTimer(), true);
        }
        response = {id: 7, unavailable: true};
        while (harness.now() - startedAt < 60 * 60 * 1000 - 5000) {
            assert.equal(await harness.runTimer(), true);
        }
        assert.equal(harness.context.bigWalletRequests.size, 1);
        if (succeeds) {
            response = {
                kind: "result", id: 7, name: "requestAccounts", provider: "ethereum",
                state: null, result: [], approvalCommitted: true,
            };
        }
        while (harness.context.bigWalletRequests.size > 0) {
            assert.equal(await harness.runTimer(), true);
            assert.ok(harness.now() - startedAt <= 61 * 60 * 1000);
        }
        const terminal = harness.postedMessages.filter(value => value.message.response?.id === 7);
        assert.equal(terminal.length, 1);
        assert.equal(terminal[0].message.response.kind, succeeds ? "result" : "error");
        assert.equal(harness.pendingTimers(), 0);
    }
});

test("an unresolved response read cannot end a native-owned request", async () => {
    let resolveRead;
    let reads = 0;
    const harness = makeHarness({sendMessage: message => {
        if (message.subject === "message-to-wallet") {
            return {
                id: 16,
                requestToken,
                admissionKind: "new", approvalRequired: true,
                state: configurationState(),
            };
        }
        if (message.subject === "getResponse") {
            reads += 1;
            if (reads === 1) {
                return new Promise(resolve => { resolveRead = resolve; });
            }
            return {
                kind: "result",
                id: 16,
                name: "requestAccounts",
                provider: "ethereum",
                state: null,
                result: [],
                approvalCommitted: false,
            };
        }
        return undefined;
    }});
    await settle();
    harness.dispatchPage("request", dappRequest(16));
    await settle();
    await harness.runTimer();
    harness.advance(15 * 60 * 1000);
    await harness.runTimer();
    assert.equal(harness.postedMessages.some(value => {
        return value.message.response?.id === 16;
    }), false);
    await harness.runTimer();
    assert.equal(harness.postedMessages.at(-1).message.response.id, 16);

    resolveRead({
        kind: "result",
        id: 16,
        name: "requestAccounts",
        provider: "ethereum",
        state: null,
        result: [],
        approvalCommitted: false,
    });
    await settle();
    assert.equal(harness.postedMessages.filter(value => {
        return value.message.response?.id === 16;
    }).length, 1);
});

test("stale generations fail visibly without entering the relay", async () => {
    const harness = makeHarness({sendMessage: () => {
        throw new Error("must not send");
    }});
    await settle();
    harness.dispatchPage("request", dappRequest(11), "stale");
    await settle();
    assert.equal(harness.postedMessages.at(-1).message.response.error?.code, -32603);
    assert.equal(harness.runtimeMessages.filter(message => {
        return message.subject === "message-to-wallet";
    }).length, 0);
});

test("ordinary RPC fails after the long content relay timeout", async () => {
    let resolveRPC;
    const harness = makeHarness({sendMessage: message => message.subject === "rpc"
        ? new Promise(resolve => { resolveRPC = resolve; })
        : undefined});
    await settle();
    harness.dispatchPage("rpc", {
        id: 18,
        chainId: "0x1",
        body: "{}",
    });
    await settle();
    const timeoutStartedAt = harness.now();
    assert.equal(await harness.runTimer(), true);
    assert.equal(harness.now() - timeoutStartedAt, 190_000);
    assert.deepEqual(harness.postedMessages.at(-1).message.response, {
        kind: "error",
        id: 18,
        provider: "ethereum",
        name: null,
        state: null,
        error: {code: -32603, message: "Failed to communicate with Big Wallet"},
    });

    resolveRPC({
        kind: "result",
        id: 18,
        result: "ok",
        provider: "ethereum",
        name: null,
        state: null,
        approvalCommitted: false,
    });
    await settle();
    assert.deepEqual(harness.postedMessages.at(-1).message.response, {
        kind: "error",
        id: 18,
        provider: "ethereum",
        name: null,
        state: null,
        error: {code: -32603, message: "Failed to communicate with Big Wallet"},
    });
});

test("relays correlated disconnects with trusted page identity", async () => {
    const harness = makeHarness({sendMessage: message => message.subject === "disconnect"
        ? {
            kind: "result",
            id: 12,
            name: "revokePermissions",
            provider: "ethereum",
            result: null,
            state: {context: "a".repeat(64), revisions: {ethereum: 1, solana: 0}, ethereum: {address: "", chainId: "0x1"}, solana: null},
            approvalCommitted: false,
        }
        : undefined});
    await settle();
    harness.dispatchPage("disconnect", {id: 12, provider: "ethereum"});
    await settle();
    const disconnect = harness.runtimeMessages.find(message => {
        return message.subject === "disconnect";
    });
    assert.equal(disconnect.host, "wallet.example");
    assert.equal(disconnect.configurationKey, "https://wallet.example");
    assert.equal(harness.postedMessages.at(-1).message.response.result, null);
    const before = harness.postedMessages.length;
    harness.context.bigWalletPublishConfiguration({context: "a".repeat(64), revisions: {ethereum: 0, solana: 0}, ethereum: {address: "0x0000000000000000000000000000000000000001", chainId: "0x1"}, solana: null}, "https://wallet.example", harness.generation());
    assert.equal(harness.postedMessages.length, before + 1);
});

test("disconnect waits for native revocation and tab notification", async () => {
    const connected = {...configurationState({ethereum: 1, solana: 0}),
        ethereum: {address: "0x0000000000000000000000000000000000000001", chainId: "0x1"}};
    const result = {
        kind: "result", id: 12, name: "revokePermissions", provider: "ethereum",
        result: null, state: configurationState({ethereum: 2, solana: 0}), approvalCommitted: false,
    };
    const harness = makeHarness({
        configurationResponse: {kind: "configuration", state: connected},
        sendMessage: async message => {
            if (message.subject !== "disconnect") { return undefined; }
            await new Promise(resolve => harness.context.setTimeout(resolve, 4500));
            await new Promise(resolve => harness.context.setTimeout(resolve, 1000));
            return result;
        },
    });
    await settle();
    harness.dispatchPage("disconnect", {id: 12, provider: "ethereum"});
    await settle();
    await harness.runTimer();
    await harness.runTimer();
    assert.deepEqual(harness.postedMessages.at(-1).message.response, result);
    assert.equal(harness.context.bigWalletConfigurationState.state.ethereum.address, "");
    assert.equal(harness.runtimeMessages.filter(message => message.subject === "disconnect").length, 1);
    assert.equal(harness.pendingTimers(), 0);
});

test("delayed disconnect snapshots reach the provider for ordered reconciliation", async () => {
    const address = "0x0000000000000000000000000000000000000001";
    const configuration = revision => ({
        kind: "configuration",
        state: {context: "a".repeat(64), revisions: {ethereum: revision, solana: 0}, ethereum: {address: address, chainId: "0x1"}, solana: null},
    });
    let resolveDisconnect;
    const harness = makeHarness({
        configurationResponse: configuration(0),
        sendMessage: message => message.subject === "disconnect"
            ? new Promise(resolve => { resolveDisconnect = resolve; })
            : undefined,
    });
    await settle();
    harness.dispatchPage("disconnect", {id: 12, provider: "ethereum"});
    await settle();
    harness.context.bigWalletPublishConfiguration(configuration(2).state, "https://wallet.example", harness.generation());
    const before = harness.postedMessages.length;
    const revokedState = {
        kind: "configuration",
        state: {context: "a".repeat(64), revisions: {ethereum: 1, solana: 0}, ethereum: {address: "", chainId: "0x1"}, solana: null},
    };
    harness.context.bigWalletPublishConfiguration(revokedState.state, "https://wallet.example", harness.generation());
    assert.equal(harness.postedMessages.length, before + 1);
    resolveDisconnect({
        kind: "result",
        id: 12,
        name: "revokePermissions",
        provider: "ethereum",
        result: null,
        state: revokedState.state,
        approvalCommitted: false,
    });
    await settle();
    const terminal = harness.postedMessages.at(-1).message;
    assert.equal(terminal.response.result, null);
    assert.deepEqual(terminal.response.state, revokedState.state);
    assert.equal(terminal.response.configurationMatch, undefined);
    assert.equal(terminal.suppressProviderUpdate, undefined);
});

test("disconnect failures do not revoke local authorization", async () => {
    for (const failure of ["timeout", "malformed"]) {
        const harness = makeHarness({
            configurationResponse: {
                kind: "configuration",
                state: {
                    context: "a".repeat(64),
                    revisions: {ethereum: 2, solana: 0},
                    ethereum: {
                        address: "0x0000000000000000000000000000000000000001",
                        chainId: "0x1",
                    },
                    solana: null,
                },
            },
            sendMessage: message => {
                if (message.subject !== "disconnect") { return undefined; }
                return failure === "timeout" ? new Promise(() => {}) : {
                    kind: "result",
                    id: 14,
                    name: "revokePermissions",
                    provider: "ethereum",
                    state: {context: "a".repeat(64), ethereum: {address: "", chainId: "0x1"}, solana: null},
                    result: null,
                    approvalCommitted: false,
                };
            },
        });
        await settle();
        const configuration = clone(harness.context.bigWalletConfigurationState);

        harness.dispatchPage("disconnect", {id: 14, provider: "ethereum"});
        await settle();
        if (failure === "timeout") { assert.equal(await harness.runTimer(), true); assert.equal(await harness.runTimer(), true); }

        assert.deepEqual(harness.postedMessages.at(-1).message.response, {
            kind: "error",
            id: 14,
            name: "revokePermissions",
            provider: "ethereum",
            state: null,
            error: {
                code: -32603,
                message: failure === "timeout"
                    ? "Failed to revoke permissions"
                    : "Failed to process provider response",
            },
        });
        assert.deepEqual(clone(harness.context.bigWalletConfigurationState), configuration);
    }
});

test("manual switch intent forwards exact trusted identity and worker status", async () => {
    const responses = [
        {
            approvalRequired: true,
            configurationKey: "https://wallet.example",
            id: 30,
            requestToken,
            revisions: {ethereum: 1, solana: 2},
            subject: "manualSwitchAcknowledged",
            workflowVersion: 4,
        },
        nativeError({
            id: 30,
            name: "switchAccount",
            provider: "multiple",
            error: {code: 4001, message: "Canceled"},
        }),
    ];
    for (const expected of responses) {
        const harness = makeHarness({sendMessage: message =>
            message.subject === "manualSwitchIntent" ? expected : undefined});
        await settle();
        const response = await harness.dispatchRuntime({
            configurationKey: "https://wallet.example",
            subject: "manualSwitchIntent",
            workflowVersion: 4,
        });

        assert.deepEqual(clone(response), expected);
        assert.deepEqual(harness.runtimeMessages.filter(message =>
            message.subject === "manualSwitchIntent"
        ), [{
            configurationKey: "https://wallet.example",
            host: "wallet.example",
            subject: "manualSwitchIntent",
            workflowVersion: 4,
        }]);
    }
});

test("manual switch intent rejects mismatched and inexact messages", async () => {
    const harness = makeHarness({sendMessage: message => {
        if (message.subject === "manualSwitchIntent") {
            assert.fail("untrusted manual intent must not reach the worker");
        }
    }});
    await settle();
    const base = {
        configurationKey: "https://wallet.example",
        subject: "manualSwitchIntent",
        workflowVersion: 4,
    };
    for (const message of [
        {...base, extra: true},
        {...base, configurationKey: "https://other.example"},
        {...base, workflowVersion: 2},
        {subject: "manualSwitchIntent", workflowVersion: 4},
        {name: "switchAccount", id: 31},
    ]) {
        assert.equal(await harness.dispatchRuntime(message), undefined);
    }
    assert.equal(harness.runtimeMessages.some(message =>
        message.subject === "manualSwitchIntent"
    ), false);

    const unavailable = makeHarness({
        failFirstInjection: true,
        sendMessage: () => assert.fail("missing provider must not forward"),
    });
    await settle();
    assert.equal(await unavailable.dispatchRuntime(base), undefined);
});

test("legacy manual-switch result broadcasts are ignored", async () => {
    const harness = makeHarness();
    await settle();
    const before = harness.postedMessages.length;
    assert.equal(await harness.dispatchRuntime({
        configurationKey: "https://wallet.example",
        response: {
            id: 31,
            name: "switchAccount",
            provider: "multiple",
            latestConfigurations: [],
            revisions: {ethereum: 1, solana: 0},
        },
        subject: "manualSwitchResult",
        workflowVersion: 4,
    }), undefined);
    assert.equal(harness.postedMessages.length, before);
});

test("manual switch adapter remains single across content reevaluation", async () => {
    const status = {
        approvalRequired: true,
        configurationKey: "https://wallet.example",
        id: 32,
        requestToken,
        revisions: {ethereum: 0, solana: 0},
        subject: "manualSwitchAcknowledged",
        workflowVersion: 4,
    };
    const harness = makeHarness({sendMessage: message =>
        message.subject === "manualSwitchIntent" ? status : undefined});
    await settle();
    harness.reevaluate();
    harness.reevaluate();
    const response = await harness.dispatchRuntime({
        configurationKey: "https://wallet.example",
        subject: "manualSwitchIntent",
        workflowVersion: 4,
    });

    assert.deepEqual(clone(response), status);
    assert.equal(harness.listenerCounts().runtime, 1);
    assert.equal(harness.runtimeMessages.filter(message =>
        message.subject === "manualSwitchIntent"
    ).length, 1);
});

test("file pages use a query-and-fragment-free configuration identity", async () => {
    const harness = makeHarness({
        url: "file:///tmp/dapp.html?profile=one#section",
        sendMessage: message => message.subject === "message-to-wallet" ? {
            id: 14,
            requestToken,
            admissionKind: "new", approvalRequired: true,
            state: configurationState(),
        } : undefined,
    });
    await settle();
    harness.dispatchPage("request", dappRequest(14));
    await settle();
    const enqueue = harness.runtimeMessages.find(message => {
        return message.subject === "message-to-wallet";
    });
    assert.equal(enqueue.configurationKey, "file:///tmp/dapp.html");
});

test("response polling delivers a terminal payload without another worker operation", async () => {
    const harness = makeHarness({sendMessage: message => {
        if (message.subject === "message-to-wallet") {
            return {id: 7, requestToken, admissionKind: "new", approvalRequired: true, state: configurationState()};
        }
        if (message.subject === "getResponse") {
            return {
                kind: "result", id: 7, name: "requestAccounts", provider: "ethereum",
                state: null, result: [], approvalCommitted: true,
            };
        }
        throw new Error("unexpected mutation");
    }});
    await settle();
    harness.dispatchPage("request", dappRequest());
    await settle();
    await harness.runTimer();
    assert.equal(harness.postedMessages.filter(value => value.message.response?.id === 7).length, 1);
    assert.deepEqual(harness.runtimeMessages.map(value => value.subject), [
        "getLatestConfiguration", "message-to-wallet", "getResponse",
    ]);
    assert.equal(harness.context.bigWalletRequests.size, 0);
    assert.equal(harness.pendingTimers(), 0);
    const query = harness.runtimeMessages.at(-1);
    assert.deepEqual(Object.keys(query).sort(), [
        "configurationKey", "id", "requestToken", "subject", "workflowVersion",
    ]);
});

test("response polling retries the same identity and waits for the explicit delivery result", async () => {
    let resolveCompletion;
    let completions = 0;
    const harness = makeHarness({sendMessage: message => {
        if (message.subject === "message-to-wallet") {
            return {id: 7, requestToken, admissionKind: "new", approvalRequired: true, state: configurationState({ethereum: 4, solana: 2})};
        }
        if (message.subject === "getResponse") {
            completions += 1;
            if (completions === 1) { throw new Error("lost delivery reply"); }
            return new Promise(resolve => { resolveCompletion = resolve; });
        }
    }});
    await settle();
    harness.dispatchPage("request", dappRequest());
    await settle();
    await harness.runTimer();
    assert.equal([...harness.context.bigWalletRequests.values()][0].phase, "waiting");
    assert.equal(harness.postedMessages.some(value => value.message.response?.id === 7), false);
    await harness.runTimer();
    assert.equal(completions, 2);
    assert.equal(harness.runtimeMessages.filter(value => value.subject === "getResponse").length, 2);
    for (const completion of harness.runtimeMessages.filter(value => value.subject === "getResponse")) {
        assert.equal(completion.requestToken, requestToken);
        assert.equal(completion.configurationKey, "https://wallet.example");
        assert.equal("revisions" in completion, false);
    }
    await harness.dispatchRuntime({subject: "responseReady", id: 7, workflowVersion: 4});
    const result = {
        kind: "result", id: 7, name: "requestAccounts", provider: "ethereum",
        state: null, result: [], approvalCommitted: true,
    };
    resolveCompletion(result);
    await settle();
    assert.equal(completions, 2);
    assert.deepEqual(harness.postedMessages.at(-1).message.response, result);
    assert.equal(harness.context.bigWalletRequests.size, 0);
    assert.equal(harness.pendingTimers(), 0);
});

test("content has no execution-liveness protocol after native approval", async () => {
    const harness = makeHarness();
    await settle();
    const before = harness.runtimeMessages.length;
    assert.equal(await harness.dispatchRuntime({subject: "requestActive", id: 7, requestToken,
        configurationKey: "https://wallet.example", workflowVersion: 4}), undefined);
    assert.equal(harness.runtimeMessages.length, before);
});

test("failed warm refresh retains the last snapshot and retries a bounded number of times", async () => {
    let reads = 0;
    const state = configurationState({ethereum: 3, solana: 0});
    const harness = makeHarness({configurationResponse: () => ++reads === 1
        ? {kind: "configuration", state} : {kind: "configurationError", error: {code: 4900, message: "Offline"}}});
    await settle();
    assert.equal(harness.nextTimerDelay(), null);
    harness.focus();
    await settle();
    await harness.runTimer();
    await harness.runTimer();
    assert.equal(reads, 4);
    assert.equal(harness.nextTimerDelay(), null);
    assert.deepEqual(clone(harness.context.bigWalletConfigurationState.state), state);
    assert.equal(harness.postedMessages.some(value => value.message.response.kind === "configurationError"), false);
});

for (const [provider, name] of [
    ["ethereum", "requestAccounts"], ["ethereum", "switchEthereumChain"],
    ["ethereum", "addEthereumChain"], ["solana", "connect"],
]) {
    test(`${provider} ${name} returns changed authority and waits for an explicit new request`, async () => {
        const state = configurationState({ethereum: 1, solana: 1});
        const error = {code: 4100, message: "Changed"};
        let admissions = 0;
        const harness = makeHarness({sendMessage: message => {
            if (message.subject !== "message-to-wallet") { return undefined; }
            return ++admissions === 1 ? {kind: "error", id: message.message.id, provider, name, state, error}
                : {id: message.message.id, requestToken, admissionKind: "new", approvalRequired: true, state};
        }});
        await settle();
        const request = {...dappRequest(), provider, name};
        if (provider === "solana") { request.body = {publicKey: "", object: {params: {}}}; }
        else if (name !== "requestAccounts") { request.body.object = {chainId: "0xa"}; }
        harness.dispatchPage("request", request);
        await settle();
        const first = harness.runtimeMessages.filter(message => message.subject === "message-to-wallet");
        assert.equal(first.length, 1);
        assert.deepEqual(first[0].message, request);
        assert.deepEqual(clone(harness.postedMessages.at(-1).message.response),
            {kind: "error", id: request.id, provider, name, state, error});
        assert.deepEqual(clone(harness.context.bigWalletConfigurationState.state), state);
        assert.equal(harness.context.bigWalletRequests.size, 0);
        assert.equal(harness.nextTimerDelay(), null);

        harness.dispatchPage("request", {...request, id: request.id + 2});
        await settle();
        const sent = harness.runtimeMessages.filter(message => message.subject === "message-to-wallet");
        assert.equal(sent.length, 2);
        assert.notEqual(sent[0].enqueueAttempt, sent[1].enqueueAttempt);
        assert.deepEqual(sent[1].authority, {context: state.context, revisions: state.revisions});
        assert.equal([...harness.context.bigWalletRequests.values()][0].phase, "waiting");
    });
}

for (const address of ["0x" + "2".repeat(40), ""]) {
    test(`chain-switch failure does not rewrite the request after ${address ? "an account change" : "disconnect"}`, async () => {
        const initial = {...configurationState(), ethereum: {address: "0x" + "1".repeat(40), chainId: "0x1"}};
        const state = {...configurationState({ethereum: 1, solana: 0}), ethereum: {address, chainId: "0x1"}};
        const harness = makeHarness({configurationResponse: {kind: "configuration", state: initial}, sendMessage: message => {
            if (message.subject !== "message-to-wallet") { return undefined; }
            return {kind: "error", id: message.message.id, provider: "ethereum",
                name: "switchEthereumChain", state, error: {code: 4100, message: "Changed"}};
        }});
        await settle();
        const request = {...dappRequest(), name: "switchEthereumChain",
            body: {...initial.ethereum, object: {chainId: "0xa"}}};
        harness.dispatchPage("request", request);
        await settle();
        const sent = harness.runtimeMessages.filter(message => message.subject === "message-to-wallet");
        assert.equal(sent.length, 1);
        assert.deepEqual(sent[0].message, request);
        assert.equal(request.body.address, initial.ethereum.address);
        assert.equal(harness.postedMessages.at(-1).message.response.error.code, 4100);
        assert.deepEqual(clone(harness.context.bigWalletConfigurationState.state), state);
        assert.equal(harness.nextTimerDelay(), null);
    });
}

test("signing and ambiguous admissions never retry with refreshed authority", async () => {
    const harness = makeHarness({sendMessage: message => message.subject === "message-to-wallet" ? {
        kind: "error", id: message.message.id, provider: "ethereum", name: "signMessage",
        state: configurationState({ethereum: 1, solana: 0}), error: {code: 4100, message: "Changed"},
    } : undefined});
    await settle();
    harness.dispatchPage("request", {...dappRequest(), name: "signMessage"});
    await settle();
    assert.equal(harness.runtimeMessages.filter(value => value.subject === "message-to-wallet").length, 1);
    assert.equal(harness.postedMessages.at(-1).message.response.error.code, 4100);
});

for (const provider of ["ethereum", "solana"]) {
    for (const outcome of ["stale", "lost-then-success", "lost-then-stale"]) {
        test(`${provider} disconnect ${outcome} never replaces its authority or identity`, async () => {
            let calls = 0;
            const state = configurationState({ethereum: 3, solana: 3});
            const error = {code: 4100, message: "Changed"};
            const succeeds = outcome === "lost-then-success";
            const harness = makeHarness({sendMessage: message => {
                if (message.subject !== "disconnect") { return undefined; }
                calls += 1;
                if (calls === 1 && outcome !== "stale") { return undefined; }
                const base = {id: message.id, provider, name: "revokePermissions", state};
                return succeeds ? {...base, kind: "result", result: null, approvalCommitted: false}
                    : {...base, kind: "error", error};
            }});
            await settle();
            harness.dispatchPage("disconnect", {id: 7, provider});
            await settle();
            const sent = harness.runtimeMessages.filter(value => value.subject === "disconnect");
            assert.equal(sent.length, outcome === "stale" ? 1 : 2);
            if (sent.length === 2) { assert.deepEqual(sent[1], sent[0]); }
            assert.deepEqual(clone(harness.context.bigWalletConfigurationState.state), state);
            const terminal = harness.postedMessages.at(-1).message.response;
            assert.equal(terminal.kind, succeeds ? "result" : "error");
            if (!succeeds) { assert.deepEqual(clone(terminal.error), error); }
            assert.equal(harness.nextTimerDelay(), null);
        });
    }
}

test("disconnect never retries a precondition from another native context", async () => {
    const harness = makeHarness({sendMessage: message => message.subject === "disconnect" ? {
        id: message.id, provider: "ethereum", name: "revokePermissions", kind: "error",
        error: {code: 4100, message: "Different context"}, state: configurationState({ethereum: 1, solana: 0}, "b".repeat(64)),
    } : undefined});
    await settle();
    const generation = harness.generation();
    harness.dispatchPage("disconnect", {id: 7, provider: "ethereum"});
    await settle();
    assert.equal(harness.runtimeMessages.filter(value => value.subject === "disconnect").length, 1);
    assert.notEqual(harness.generation(), generation);
    const terminal = harness.postedMessages.at(-1).message;
    assert.equal(terminal.providerGeneration, generation);
    assert.equal(terminal.response.state, null);
});

for (const provider of ["ethereum", "solana"]) {
    test(`${provider} queued page signing keeps its observed revision after same-account revoke and regrant`, async () => {
        const observed = 1;
        const current = 3;
        const initialState = configurationState({ethereum: 1, solana: 1});
        const refreshedState = configurationState({ethereum: 3, solana: 3});
        const harness = makeHarness({configurationResponse: {kind: "configuration", state: initialState},
            sendMessage: message => {
                if (message.subject !== "message-to-wallet") { return undefined; }
                assert.equal(message.authority.revisions[provider], observed);
                assert.equal(message.authority.revisions[provider === "ethereum" ? "solana" : "ethereum"], current);
                assert.deepEqual(Object.keys(message.message).sort(), ["body", "id", "name", "provider"]);
                return {kind: "error", id: message.message.id, provider, name: "signMessage",
                    state: refreshedState, error: {code: 4100, message: "Authorization changed"}};
            }});
        await settle();
        const generation = harness.generation();
        const queued = {id: 7, provider, name: "signMessage", body: provider === "ethereum"
            ? {address: "", chainId: "0x1", object: {data: "0x01"}}
            : {publicKey: "", object: {message: "2"}}};
        harness.context.bigWalletPublishConfiguration(refreshedState, "https://wallet.example", generation);
        harness.dispatchPage("request", queued, generation, observed);
        await settle();
        assert.equal(harness.runtimeMessages.filter(message => message.subject === "message-to-wallet").length, 1);
        assert.equal(harness.postedMessages.at(-1).message.response.error.code, 4100);
    });
}

test("page requests reject missing malformed and overflowing observed revisions", async () => {
    const harness = makeHarness();
    await settle();
    for (const observedRevision of [null, -1, 1.5, "1", Number.MAX_SAFE_INTEGER + 1]) {
        harness.dispatchPage("request", dappRequest(), harness.generation(), observedRevision);
    }
    harness.context.bigWalletEnqueue(dappRequest(), harness.generation(), undefined);
    await settle();
    assert.equal(harness.runtimeMessages.filter(message => message.subject === "message-to-wallet").length, 0);
});
