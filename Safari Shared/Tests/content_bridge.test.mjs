// ∅ 2026 lil org

import assert from "node:assert/strict";
import {webcrypto} from "node:crypto";
import {readFile} from "node:fs/promises";
import test from "node:test";
import vm from "node:vm";

const [wireSource, contentSource] = await Promise.all([
    readFile(new URL("../Resources/bridge_wire.js", import.meta.url), "utf8"),
    readFile(new URL("../Resources/content.js", import.meta.url), "utf8"),
]);
const requestToken = "123e4567-e89b-12d3-a456-426614174000";
const manualAdmissionDeadline = 1_700_000_900_000;
const manualEnqueueAttempt = "00000001000000020000000300000004";

function clone(value) {
    return typeof value === "undefined" ? undefined : JSON.parse(JSON.stringify(value));
}

async function settle() {
    for (let index = 0; index < 20; index += 1) { await Promise.resolve(); }
}

function makeHarness({
    buildVersion = "1.0.99",
    configurationResponse,
    failFirstInjection = false,
    sendMessage,
    url = "https://wallet.example/dapp",
} = {}) {
    const runtimeMessages = [];
    const postedMessages = [];
    const timers = [];
    const injectedScripts = [];
    const pageListeners = [];
    const runtimeListeners = [];
    const focusListeners = [];
    const visibilityListeners = [];
    let injectionAttempts = 0;
    let clock = 1_700_000_000_000;
    let manifestVersion = buildVersion;
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
            getManifest() { return {version: manifestVersion}; },
            getURL() { return "safari-web-extension://wallet/inpage.js"; },
            onMessage: {addListener(listener) { runtimeListeners.push(listener); }},
            sendMessage(message) {
                runtimeMessages.push(clone(message));
                if (message.subject === "getLatestConfiguration") {
                    return Promise.resolve(
                        typeof configurationResponse === "function"
                            ? configurationResponse(message)
                            : configurationResponse || {
                                latestConfigurations: [],
                                revisions: {ethereum: 0, solana: 0},
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
    new vm.Script(wireSource).runInContext(context);
    new vm.Script(contentSource).runInContext(context);
    return {
        context,
        injectedScripts,
        postedMessages,
        runtimeMessages,
        generation: () => context.bigWalletProviderGeneration,
        injectionAttempts: () => injectionAttempts,
        listenerCounts: () => ({
            focus: focusListeners.length,
            page: pageListeners.length,
            runtime: runtimeListeners.length,
            visibility: visibilityListeners.length,
        }),
        pendingTimers: () => timers.filter(timer => !timer.cancelled).length,
        now: () => clock,
        dispatchPage(kind, message, generation = context.bigWalletProviderGeneration) {
            for (const listener of pageListeners) {
                listener({
                    source: window,
                    data: {
                        direction: "big-wallet-provider-v1",
                        kind,
                        message,
                        providerGeneration: generation,
                    },
                });
            }
        },
        dispatchRuntime(message) {
            return new Promise(resolve => {
                for (const listener of runtimeListeners) {
                    listener(message, {}, resolve);
                }
            });
        },
        reevaluate() { new vm.Script(contentSource).runInContext(context); },
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
        setBuildVersion(value) { manifestVersion = value; },
    };
}

function dappRequest(id = 7) {
    return {
        id,
        name: "requestAccounts",
        provider: "ethereum",
        body: {address: "", chainId: "0x1"},
    };
}

test("content reevaluation keeps one provider lifecycle and request bridge", async () => {
    const harness = makeHarness();
    await settle();
    const firstGeneration = harness.generation();
    assert.equal(typeof firstGeneration, "string");
    assert.equal(harness.runtimeMessages[0].subject, "getLatestConfiguration");
    assert.equal(harness.runtimeMessages[0].workflowVersion, 3);
    assert.equal(harness.postedMessages[0].message.response.latestConfigurations.length, 0);
    harness.reevaluate();
    await settle();
    assert.equal(harness.generation(), firstGeneration);
    assert.equal(harness.injectedScripts.length, 1);
    assert.equal(harness.runtimeMessages.filter(message => {
        return message.subject === "getLatestConfiguration";
    }).length, 1);
});

test("content scripts publish their captured build version directly", async () => {
    const harness = makeHarness();
    await settle();
    const runtimeMessageCount = harness.runtimeMessages.length;
    assert.deepEqual(clone(await harness.dispatchRuntime({
        nonce: manualEnqueueAttempt,
        subject: "workflowProbe",
        workflowVersion: 3,
    })), {
        buildVersion: "1.0.99",
        nonce: manualEnqueueAttempt,
        subject: "workflowProbe",
        workflowVersion: 3,
    });
    assert.equal(harness.runtimeMessages.length, runtimeMessageCount);

    harness.setBuildVersion("2.0.0");
    harness.reevaluate();
    assert.deepEqual(clone(await harness.dispatchRuntime({
        nonce: manualEnqueueAttempt,
        subject: "workflowProbe",
        workflowVersion: 3,
    })), {
        buildVersion: "1.0.99",
        nonce: manualEnqueueAttempt,
        subject: "workflowProbe",
        workflowVersion: 3,
    });

    for (const probe of [
        {subject: "workflowProbe", workflowVersion: 3},
        {nonce: "forged", subject: "workflowProbe", workflowVersion: 3},
        {nonce: manualEnqueueAttempt, subject: "workflowProbe", workflowVersion: 2},
        {
            nonce: manualEnqueueAttempt,
            subject: "workflowProbe",
            workflowVersion: 3,
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

test("three failed configuration reads emit one terminal generation failure", async () => {
    const harness = makeHarness({
        configurationResponse: {
            configurationReadFailed: true,
        },
    });
    await settle();
    await harness.runTimer();
    await harness.runTimer();

    const failures = harness.postedMessages.filter(value => {
        return value.message.kind === "configurationError";
    });
    assert.deepEqual(failures, [{
        message: {
            direction: "big-wallet-content-v1",
            kind: "configurationError",
            providerGeneration: harness.generation(),
        },
        target: "*",
    }]);
    assert.equal(await harness.runTimer(), false);
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
    assert.equal(harness.postedMessages.at(-1).message.kind, "configurationError");
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
        assert.equal(harness.postedMessages.at(-1).message.kind, "configurationError");
    }
});

test("a passive configuration cancels a scheduled bootstrap retry", async () => {
    const harness = makeHarness({
        configurationResponse: {configurationReadFailed: true},
    });
    await settle();
    assert.equal(harness.runtimeMessages.filter(message => {
        return message.subject === "getLatestConfiguration";
    }).length, 1);

    await harness.dispatchRuntime({
        subject: "configurationChanged",
        configurationKey: "https://wallet.example",
        latestConfigurations: [],
        revisions: {ethereum: 1, solana: 0},
        workflowVersion: 3,
    });
    assert.equal(await harness.runTimer(), true);

    assert.equal(harness.runtimeMessages.filter(message => {
        return message.subject === "getLatestConfiguration";
    }).length, 1);
    assert.equal(harness.postedMessages.some(value => {
        return value.message.kind === "configurationError";
    }), false);
    assert.equal(await harness.runTimer(), false);
});

test("a passive configuration satisfies an in-flight bootstrap retry", async () => {
    let resolveRetry;
    let readCount = 0;
    const harness = makeHarness({configurationResponse() {
        readCount += 1;
        if (readCount === 1) { return {configurationReadFailed: true}; }
        return new Promise(resolve => { resolveRetry = resolve; });
    }});
    await settle();
    assert.equal(await harness.runTimer(), true);
    assert.equal(readCount, 2);

    await harness.dispatchRuntime({
        subject: "configurationChanged",
        configurationKey: "https://wallet.example",
        latestConfigurations: [],
        revisions: {ethereum: 1, solana: 0},
        workflowVersion: 3,
    });
    resolveRetry({configurationReadFailed: true});
    await settle();

    assert.equal(readCount, 2);
    assert.equal(harness.postedMessages.some(value => {
        return value.message.kind === "configurationError";
    }), false);
    assert.equal(await harness.runTimer(), false);
});

test("an explicit attempt-zero refresh still reads accepted configuration", async () => {
    let readCount = 0;
    const harness = makeHarness({configurationResponse() {
        readCount += 1;
        return {
            latestConfigurations: [],
            revisions: {ethereum: readCount - 1, solana: 0},
        };
    }});
    await settle();
    assert.equal(readCount, 1);

    harness.dispatchPage("disconnect", {provider: "solana"});
    await settle();

    assert.equal(readCount, 2);
    assert.deepEqual(harness.postedMessages.at(-1).message.response.revisions, {
        ethereum: 1,
        solana: 0,
    });
});

test("focus and visibility reconcile configuration after a missed broadcast", async () => {
    let ethereumRevision = 0;
    const harness = makeHarness({configurationResponse: () => ({
        latestConfigurations: [],
        revisions: {ethereum: ethereumRevision, solana: 0},
    })});
    await settle();

    ethereumRevision = 1;
    harness.focus();
    await settle();
    assert.deepEqual(harness.postedMessages.at(-1).message.response.revisions, {
        ethereum: 1,
        solana: 0,
    });

    ethereumRevision = 2;
    harness.show();
    await settle();
    assert.deepEqual(harness.postedMessages.at(-1).message.response.revisions, {
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
            latestConfigurations: [],
            revisions: {ethereum: readCount === 1 ? 5 : 1, solana: 0},
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
            latestConfigurations: [],
            revisions: {ethereum: 1, solana: 0},
        },
        id: harness.postedMessages.at(-1).message.id,
        providerGeneration: replacementGeneration,
    });

    await harness.context.bigWalletLoadConfiguration(replacementGeneration, 1);
    assert.equal(readCount, 2);
    assert.equal(harness.postedMessages.some(value => {
        return value.message.kind === "configurationError";
    }), false);
});

test("matching passive configuration notifications update the current page", async () => {
    const harness = makeHarness();
    await settle();
    const before = harness.postedMessages.length;
    await harness.dispatchRuntime({
        subject: "configurationChanged",
        configurationKey: "https://wallet.example",
        latestConfigurations: [{
            provider: "ethereum",
            chainId: "0x1",
            results: ["0x0000000000000000000000000000000000000001"],
            accountRevision: 2,
        }],
        revisions: {ethereum: 2, solana: 0},
        workflowVersion: 3,
    });
    assert.equal(harness.postedMessages.length, before + 1);
    assert.deepEqual(harness.postedMessages.at(-1), {
        message: {
            direction: "big-wallet-content-v1",
            kind: "response",
            response: {
                latestConfigurations: [{
                    provider: "ethereum",
                    chainId: "0x1",
                    results: ["0x0000000000000000000000000000000000000001"],
                    accountRevision: 2,
                }],
                revisions: {ethereum: 2, solana: 0},
            },
            id: harness.postedMessages.at(-1).message.id,
            providerGeneration: harness.generation(),
        },
        target: "*",
    });

    await harness.dispatchRuntime({
        subject: "configurationChanged",
        configurationKey: "http://wallet.example",
        latestConfigurations: [],
        revisions: {ethereum: 3, solana: 0},
        workflowVersion: 3,
    });
    assert.equal(harness.postedMessages.length, before + 1);

    await harness.dispatchRuntime({
        subject: "configurationChanged",
        configurationKey: "https://wallet.example",
        latestConfigurations: [],
        revisions: {ethereum: 1, solana: 0},
        workflowVersion: 3,
    });
    assert.equal(harness.postedMessages.length, before + 1);
});

test("a stale terminal snapshot settles without rolling provider state back", async () => {
    const address = "0x0000000000000000000000000000000000000001";
    const harness = makeHarness({sendMessage: message => {
        if (message.subject !== "message-to-wallet") { return undefined; }
        return {
            id: 7,
            name: "requestAccounts",
            provider: "ethereum",
            results: [address],
            latestConfigurations: [{
                provider: "ethereum",
                chainId: "0x1",
                results: [address],
            }],
            revisions: {ethereum: 1, solana: 0},
        };
    }});
    await settle();
    await harness.dispatchRuntime({
        subject: "configurationChanged",
        configurationKey: "https://wallet.example",
        latestConfigurations: [],
        revisions: {ethereum: 2, solana: 0},
        workflowVersion: 3,
    });
    harness.dispatchPage("request", dappRequest(7));
    await settle();

    const terminal = harness.postedMessages.at(-1).message;
    assert.equal(terminal.response.id, 7);
    assert.equal(terminal.response.latestConfigurations, undefined);
    assert.equal(terminal.response.revisions, undefined);
    assert.equal(terminal.suppressProviderUpdate, true);
});

test("a malformed revisioned terminal fails closed", async () => {
    const harness = makeHarness({sendMessage: message => {
        if (message.subject !== "message-to-wallet") { return undefined; }
        return {
            id: 7,
            name: "requestAccounts",
            provider: "ethereum",
            results: ["0x0000000000000000000000000000000000000001"],
            latestConfigurations: [{
                provider: "ethereum",
                chainId: "0x1",
                results: ["0x0000000000000000000000000000000000000001"],
            }],
        };
    }});
    await settle();
    harness.dispatchPage("request", dappRequest(7));
    await settle();

    const terminal = harness.postedMessages.at(-1).message;
    assert.equal(terminal.response.errorCode, -32603);
    assert.equal(terminal.response.result, undefined);
    assert.equal(terminal.suppressProviderUpdate, undefined);
});

test("page-authored unknown provider requests never enter the relay", async () => {
    const harness = makeHarness();
    await settle();
    harness.dispatchPage("request", {
        id: 6,
        name: "switchAccount",
        provider: "unknown",
        body: {latestConfigurations: []},
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
            approvalRequired: true,
            revisions: {ethereum: 0, solana: 0},
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
            approvalRequired: true,
            revisions: {ethereum: 0, solana: 0},
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
    assert.equal(enqueues[0].enqueueAttempt, enqueues[1].enqueueAttempt);
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
        id: 34,
        name: "requestAccounts",
        provider: "ethereum",
        error: "Failed to communicate with Big Wallet",
        errorCode: -32603,
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

test("a capacity-rejected manual switch can retry the same admission later", async () => {
    const harness = makeHarness({sendMessage: message => {
        if (message.subject !== "message-to-wallet" || !message.manualSwitch) {
            return undefined;
        }
        return {
            id: 35,
            requestToken,
            approvalRequired: true,
            revisions: {ethereum: 1, solana: 2},
        };
    }});
    await settle();
    for (let id = 40; id < 44; id += 1) {
        harness.dispatchPage("request", dappRequest(id));
    }
    await settle();
    const popupMessage = {
        name: "switchAccount",
        id: 35,
        admissionDeadline: manualAdmissionDeadline,
        enqueueAttempt: manualEnqueueAttempt,
        expectedConfigurationKey: "https://wallet.example",
        message: {
            id: 35,
            name: "switchAccount",
            provider: "unknown",
            body: {latestConfigurations: []},
        },
    };

    assert.equal(await harness.dispatchRuntime(popupMessage), undefined);
    assert.equal(harness.context.bigWalletRequests.size, 4);
    assert.equal(harness.pendingTimers(), 4);
    assert.equal(harness.runtimeMessages.some(message => {
        return message.subject === "message-to-wallet" && message.message.id === 35;
    }), false);

    harness.context.bigWalletFail(
        Array.from(harness.context.bigWalletRequests.values())[0]
    );
    const response = await harness.dispatchRuntime(popupMessage);
    assert.equal(response.requestToken, requestToken);
    const enqueue = harness.runtimeMessages.find(message => {
        return message.subject === "message-to-wallet" && message.message.id === 35;
    });
    assert.equal(enqueue.enqueueAttempt, manualEnqueueAttempt);
    assert.equal(enqueue.admissionDeadline, manualAdmissionDeadline);
    assert.equal(enqueue.manualSwitch, true);
});

test("reads and delivers one retained response", async () => {
    const harness = makeHarness({sendMessage: message => {
        if (message.subject === "message-to-wallet") {
            return {
                id: 9,
                requestToken,
                approvalRequired: false,
                revisions: {ethereum: 0, solana: 0},
            };
        }
        if (message.subject === "getResponse") {
            return {
                id: 9,
                name: "requestAccounts",
                provider: "ethereum",
                chainId: "0x1",
                results: [],
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
    assert.equal(harness.runtimeMessages.length, 3);
});

test("an evicted retained response fails immediately", async () => {
    const harness = makeHarness({sendMessage: message => {
        if (message.subject === "message-to-wallet") {
            return {
                id: 18,
                requestToken,
                approvalRequired: false,
                revisions: {ethereum: 0, solana: 0},
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
    assert.equal(response.errorCode, -32603);
    assert.equal(await harness.runTimer(), false);
});

test("response-ready hints wake a waiting request", async () => {
    let ready = false;
    const harness = makeHarness({sendMessage: message => {
        if (message.subject === "message-to-wallet") {
            return {
                id: 10,
                requestToken,
                approvalRequired: true,
                revisions: {ethereum: 0, solana: 0},
            };
        }
        if (message.subject === "getResponse" && ready) {
            return {id: 10, name: "requestAccounts", provider: "ethereum", results: []};
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
        workflowVersion: 3,
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
                approvalRequired: true,
                revisions: {ethereum: 0, solana: 0},
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
        workflowVersion: 3,
    });

    resolveFirstRead();
    await settle();
    assert.equal(reads, 2);
    assert.equal(harness.pendingTimers(), 1);
    resolveSecondRead({
        id: 11,
        name: "requestAccounts",
        provider: "ethereum",
        results: [],
    });
    await settle();
    assert.equal(harness.postedMessages.some(value => {
        return value.message.response?.id === 11;
    }), true);
    assert.equal(await harness.runTimer(), false);
});

test("admitted requests remain native-owned past the admission deadline", async () => {
    let ready = false;
    const harness = makeHarness({sendMessage: message => {
        if (message.subject === "message-to-wallet") {
            return {
                id: 15,
                requestToken,
                approvalRequired: true,
                revisions: {ethereum: 0, solana: 0},
            };
        }
        if (message.subject === "getResponse" && ready) {
            return {id: 15, name: "requestAccounts", provider: "ethereum", results: []};
        }
        return undefined;
    }});
    await settle();
    harness.dispatchPage("request", dappRequest(15));
    await settle();
    harness.advance(15 * 60 * 1000);
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
});

test("an unresolved response read cannot end a native-owned request", async () => {
    let resolveRead;
    let reads = 0;
    const harness = makeHarness({sendMessage: message => {
        if (message.subject === "message-to-wallet") {
            return {
                id: 16,
                requestToken,
                approvalRequired: true,
                revisions: {ethereum: 0, solana: 0},
            };
        }
        if (message.subject === "getResponse") {
            reads += 1;
            if (reads === 1) {
                return new Promise(resolve => { resolveRead = resolve; });
            }
            return {id: 16, name: "requestAccounts", provider: "ethereum", results: []};
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

    resolveRead({id: 16, name: "requestAccounts", provider: "ethereum", results: []});
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
    assert.equal(harness.postedMessages.at(-1).message.response.errorCode, -32603);
    assert.equal(harness.runtimeMessages.filter(message => {
        return message.subject === "message-to-wallet";
    }).length, 0);
});

test("ordinary RPC waits without a content relay timer", async () => {
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
    assert.equal(await harness.runTimer(), false);
    assert.equal(harness.postedMessages.some(value => {
        return value.message.kind === "rpc";
    }), false);

    resolveRPC({id: 18, result: "ok"});
    await settle();
    assert.deepEqual(harness.postedMessages.at(-1).message.response, {
        id: 18,
        result: "ok",
    });
});

test("relays correlated disconnects with trusted page identity", async () => {
    const harness = makeHarness({sendMessage: message => message.subject === "disconnect"
        ? {id: 12, name: "revokePermissions", provider: "ethereum", result: null}
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
});

test("submits popup Switch Account through the ordinary request path", async () => {
    const harness = makeHarness({sendMessage: message => message.subject ===
        "message-to-wallet" ? {
            id: 13,
            requestToken,
            approvalRequired: true,
            revisions: {ethereum: 1, solana: 2},
        } : undefined});
    await settle();
    const response = await harness.dispatchRuntime({
        name: "switchAccount",
        id: 13,
        admissionDeadline: manualAdmissionDeadline,
        enqueueAttempt: manualEnqueueAttempt,
        expectedConfigurationKey: "https://wallet.example",
        message: {
            id: 13,
            name: "switchAccount",
            provider: "unknown",
            body: {latestConfigurations: []},
        },
    });
    assert.equal(response.requestToken, requestToken);
    const enqueue = harness.runtimeMessages.find(message => {
        return message.subject === "message-to-wallet" && message.message.id === 13;
    });
    assert.equal(enqueue.message.provider, "unknown");
    assert.equal(enqueue.enqueueAttempt, manualEnqueueAttempt);
    assert.equal(enqueue.admissionDeadline, manualAdmissionDeadline);
});

test("popup Switch Account rejects partial and malformed admission pairs", async () => {
    const harness = makeHarness({sendMessage: () => {
        assert.fail("invalid manual admission must not reach the worker");
    }});
    await settle();
    const base = {
        name: "switchAccount",
        id: 21,
        expectedConfigurationKey: "https://wallet.example",
        message: {
            id: 21,
            name: "switchAccount",
            provider: "unknown",
            body: {latestConfigurations: []},
        },
    };
    const invalid = [
        {},
        {enqueueAttempt: manualEnqueueAttempt},
        {admissionDeadline: manualAdmissionDeadline},
        {enqueueAttempt: "invalid", admissionDeadline: manualAdmissionDeadline},
        {enqueueAttempt: manualEnqueueAttempt, admissionDeadline: 0},
        {enqueueAttempt: manualEnqueueAttempt, admissionDeadline: -1},
        {enqueueAttempt: manualEnqueueAttempt, admissionDeadline: 1.5},
        {enqueueAttempt: manualEnqueueAttempt, admissionDeadline: "1"},
        {
            enqueueAttempt: manualEnqueueAttempt,
            admissionDeadline: Number.MAX_SAFE_INTEGER + 1,
        },
    ];

    for (const values of invalid) {
        assert.equal(await harness.dispatchRuntime({...base, ...values}), undefined);
    }
    assert.equal(harness.runtimeMessages.some(message => {
        return message.subject === "message-to-wallet";
    }), false);
});

test("popup Switch Account retries with one attempt and deadline", async () => {
    let calls = 0;
    const harness = makeHarness({sendMessage: message => {
        if (message.subject !== "message-to-wallet") { return undefined; }
        calls += 1;
        return calls === 1 ? undefined : {
            id: 20,
            requestToken,
            approvalRequired: true,
            revisions: {ethereum: 1, solana: 2},
        };
    }});
    await settle();
    const popupMessage = {
        name: "switchAccount",
        id: 20,
        admissionDeadline: manualAdmissionDeadline,
        enqueueAttempt: manualEnqueueAttempt,
        expectedConfigurationKey: "https://wallet.example",
        message: {
            id: 20,
            name: "switchAccount",
            provider: "unknown",
            body: {latestConfigurations: []},
        },
    };
    const pending = harness.dispatchRuntime(popupMessage);
    await settle();
    await harness.runTimer();

    assert.equal((await pending).requestToken, requestToken);
    const enqueues = harness.runtimeMessages.filter(message => {
        return message.subject === "message-to-wallet" && message.message.id === 20;
    });
    assert.equal(enqueues.length, 2);
    assert.equal(enqueues.every(message => message.manualSwitch === true), true);
    assert.equal(enqueues[0].enqueueAttempt, enqueues[1].enqueueAttempt);
    assert.equal(enqueues[0].admissionDeadline, enqueues[1].admissionDeadline);
});

test("popup Switch Account stays deduplicated across content reevaluation", async () => {
    const harness = makeHarness({sendMessage: message => message.subject ===
        "message-to-wallet" ? {
            id: 17,
            requestToken,
            approvalRequired: true,
            revisions: {ethereum: 1, solana: 2},
        } : undefined});
    await settle();
    const popupMessage = {
        name: "switchAccount",
        id: 17,
        admissionDeadline: manualAdmissionDeadline,
        enqueueAttempt: manualEnqueueAttempt,
        expectedConfigurationKey: "https://wallet.example",
        message: {
            id: 17,
            name: "switchAccount",
            provider: "unknown",
            body: {latestConfigurations: []},
        },
    };
    void harness.dispatchRuntime(popupMessage);
    harness.reevaluate();
    await settle();
    const response = await harness.dispatchRuntime(popupMessage);

    assert.equal(response.requestToken, requestToken);
    const enqueues = harness.runtimeMessages.filter(message => {
        return message.subject === "message-to-wallet" && message.message.id === 17;
    });
    assert.equal(enqueues.length, 1);
    assert.equal(enqueues[0].enqueueAttempt, popupMessage.enqueueAttempt);
    assert.equal(enqueues[0].manualSwitch, true);
    assert.equal(enqueues[0].admissionDeadline, popupMessage.admissionDeadline);
});

test("popup Switch Account preserves admission across fresh content realms", async () => {
    const popupMessage = {
        name: "switchAccount",
        id: 22,
        admissionDeadline: manualAdmissionDeadline,
        enqueueAttempt: manualEnqueueAttempt,
        expectedConfigurationKey: "https://wallet.example",
        message: {
            id: 22,
            name: "switchAccount",
            provider: "unknown",
            body: {latestConfigurations: []},
        },
    };
    const first = makeHarness({sendMessage: () => undefined});
    await settle();
    void first.dispatchRuntime(popupMessage);
    await settle();

    const second = makeHarness({sendMessage: message => {
        return message.subject === "message-to-wallet" ? {
            id: 22,
            requestToken,
            approvalRequired: true,
            revisions: {ethereum: 1, solana: 2},
        } : undefined;
    }});
    await settle();
    second.advance(60_000);
    const response = await second.dispatchRuntime(popupMessage);

    assert.equal(response.requestToken, requestToken);
    for (const harness of [first, second]) {
        const enqueue = harness.runtimeMessages.find(message => {
            return message.subject === "message-to-wallet" && message.message.id === 22;
        });
        assert.equal(enqueue.enqueueAttempt, manualEnqueueAttempt);
        assert.equal(enqueue.admissionDeadline, manualAdmissionDeadline);
    }
});

test("file pages use a query-and-fragment-free configuration identity", async () => {
    const harness = makeHarness({
        url: "file:///tmp/dapp.html?profile=one#section",
        sendMessage: message => message.subject === "message-to-wallet" ? {
            id: 14,
            requestToken,
            approvalRequired: true,
            revisions: {ethereum: 0, solana: 0},
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
