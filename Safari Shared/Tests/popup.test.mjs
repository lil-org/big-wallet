// ∅ 2026 lil org

import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import vm from "node:vm";
import { deferred, normalized, popupElement } from "./test_helpers.mjs";

const [source, wireSource, markup] = await Promise.all([
    readFile(new URL("../Resources/popup.js", import.meta.url), "utf8"),
    readFile(new URL("../Resources/bridge_wire.js", import.meta.url), "utf8"),
    readFile(new URL("../Resources/popup.html", import.meta.url), "utf8"),
]);
const packagedBuildVersion = wireSource.match(
    /const BUILD_VERSION = "([^"\n]+)";/
)?.[1];
assert.match(packagedBuildVersion, /^.+\+[0-9]+$/);
const previousBuildVersion = packagedBuildVersion.replace(
    /[0-9]+$/,
    value => String(Math.max(0, Number(value) - 1))
);

test("manual Switch Account allows a full native admission window", () => {
    const nativeTimeout = Number(source.match(
        /const NATIVE_MESSAGE_TIMEOUT = (\d+);/
    )[1]);
    const multiplier = Number(source.match(
        /const MANUAL_SWITCH_TIMEOUT = NATIVE_MESSAGE_TIMEOUT \* (\d+);/
    )[1]);
    assert.equal(nativeTimeout * multiplier, 10_000);
    const nativeOperationRelayTimeout = Number(source.match(
        /const NATIVE_OPERATION_RELAY_TIMEOUT = (\d+) \* 1000;/
    )[1]) * 1000;
    assert.equal(nativeOperationRelayTimeout, 190_000);
});

test("popup never renders or transports a wallet password", () => {
    assert.doesNotMatch(markup, /type="password"|password-input|password-row/);
    assert.doesNotMatch(source, /payload\.password|canUsePassword/);
    assert.match(source, /Password payloads are not supported/);
});

test("uses the direct sender except for serialized approval", () => {
    assert.match(source, /createTrustedNativeMessageSender\(\{\s*sendRawNativeMessage,\s*\}\)/);
    assert.match(source, /subject: "approveRequestWithCurrentRevisions"/);
    assert.doesNotMatch(source, /PRIVATE_BROWSING_CAPABILITY_TIMEOUT|capabilityTimeoutMilliseconds/);
});

test("manual Switch Account is a stateless content intent", () => {
    assert.match(source, /browser\.tabs\.sendMessage\(tab\.id, message\)/);
    assert.match(source, /configurationKey: tab\.configurationKey,\s+subject: BigWalletBridgeWire\.MANUAL_SWITCH_INTENT_SUBJECT,\s+workflowVersion: WORKFLOW_VERSION/);
    const manual = extractedFunction("switchAccountFromIdle");
    assert.doesNotMatch(manual,
        /genId|genPrivateToken|admissionDeadline|enqueueAttempt|latestConfigurations|readLatestConfiguration|manualSwitchAttempt/);
});

test("configuration reads carry trusted tab identity", () => {
    assert.match(source, /subject: "getLatestConfiguration",\s+host: tab\.host,\s+configurationKey: tab\.configurationKey,\s+workflowVersion: WORKFLOW_VERSION/);
});

test("defines the bounded extension-message transport used during boot", () => {
    assert.match(source, /async function settleExtensionMessage\(/);
    assert.match(source, /withTimeout\(pendingResponse, milliseconds\)/);
});

test("native approve uses the worker proxy while other commands stay direct", async () => {
    const extensionMessages = [];
    const nativeMessages = [];
    const context = vm.createContext({
        WORKFLOW_VERSION: 3,
        browser: {runtime: {sendMessage(message) {
            extensionMessages.push(message);
            return Promise.resolve({status: "ok"});
        }}},
        currentPrivateBrowsing: () => false,
        isRecord: value => value !== null && typeof value === "object" &&
            !Array.isArray(value),
        sendTrustedNativeMessage(message, privateBrowsing) {
            nativeMessages.push({message, privateBrowsing});
            return Promise.resolve({status: "ok"});
        },
    });
    const nativeMessage = vm.runInContext(
        `(${extractedFunction("nativeMessage")})`,
        context
    );
    const request = {
        host: "wallet.example",
        configurationKey: "https://wallet.example",
    };

    await nativeMessage(
        "approveRequest",
        7,
        {cluster: "devnet"},
        "123e4567-e89b-12d3-a456-426614174000",
        "123e4567-e89b-12d3-a456-426614174001",
        request
    );
    await nativeMessage("rejectRequest", 7, undefined, "token");
    await assert.rejects(
        nativeMessage(
            "approveRequest",
            8,
            {password: "must-not-cross-native-boundary"},
            "123e4567-e89b-12d3-a456-426614174000",
            "123e4567-e89b-12d3-a456-426614174001",
            request
        ),
        /Password payloads are not supported/
    );

    assert.deepEqual(JSON.parse(JSON.stringify(extensionMessages)), [{
        subject: "approveRequestWithCurrentRevisions",
        id: 7,
        host: "wallet.example",
        configurationKey: "https://wallet.example",
        requestToken: "123e4567-e89b-12d3-a456-426614174000",
        reviewToken: "123e4567-e89b-12d3-a456-426614174001",
        payload: {cluster: "devnet"},
        privateBrowsing: false,
        workflowVersion: 3,
    }]);
    assert.equal(nativeMessages.length, 1);
    assert.equal(nativeMessages[0].message.subject, "rejectRequest");
});

test("update recovery captures one build and uses one click-time lookup", () => {
    assert.match(source,
        /const BUILD_VERSION = BigWalletBridgeWire\.BUILD_VERSION;/);
    assert.doesNotMatch(source, /const BUILD_VERSION = "[^"\n]*";/);
    assert.match(wireSource, /const BUILD_VERSION = "[^"\n]+\+[0-9]+";/);
    assert.doesNotMatch(source, /BUILD_VERSION = browser\.runtime\.getManifest/);
    const refresh = extractedFunction("refreshIdleStatus");
    assert.equal(refresh.match(/currentActiveTab\(\)/g)?.length, 1);
    assert.doesNotMatch(refresh, /readUpdateRecoveryFlag/);
});

test("pending and completed queue entries require exact trusted identities", () => {
    const context = {
        hasExactKeys: (value, keys) => value !== null &&
            typeof value === "object" &&
            Object.keys(value).length === keys.length &&
            keys.every(key => Object.hasOwn(value, key)),
        isRecord: value => value !== null && typeof value === "object" &&
            !Array.isArray(value),
        isValidRequestId: Number.isSafeInteger,
        isRequestToken: value => typeof value === "string",
        isPrivateToken: value => typeof value === "string",
        isProviderRevisions: value => value?.ethereum === 1 && value?.solana === 2,
    };
    vm.createContext(context);
    const isPendingRequest = vm.runInContext(
        `(${extractedFunction("isPendingRequest")})`,
        context
    );
    const request = {
        configurationKey: "https://wallet.example",
        host: "wallet.example",
        id: 7,
        provider: "ethereum",
        receivedAt: Date.now(),
        requestToken: "request",
        revisions: {ethereum: 1, solana: 2},
        sequence: 0,
    };
    assert.equal(isPendingRequest(request), true);
    assert.equal(isPendingRequest({...request, configurationKey: undefined}), false);
    assert.equal(isPendingRequest({...request, provider: "other"}), false);
    assert.equal(isPendingRequest({...request, revisions: undefined}), false);

    const isCompletedResponse = vm.runInContext(
        `(${extractedFunction("isCompletedResponse")})`,
        context
    );
    const completed = {
        id: 8,
        host: "wallet.example",
        configurationKey: "https://wallet.example",
        requestToken: "request",
        revisions: {ethereum: 1, solana: 2},
    };
    assert.equal(isCompletedResponse(completed), true);
    assert.equal(isCompletedResponse({...completed, extra: true}), false);
    assert.equal(isCompletedResponse({...completed, revisions: undefined}), false);
});

test("approval envelope validates capabilities and requires canonical review content", () => {
    const harness = popupHarness();
    const request = pendingRequest();
    const error = {id: request.id, state: "error", actions: ["retry"], error: "Failed"};
    const rejectable = {...error, actions: ["reject"]};
    for (const state of [
        messageState(request), transactionState(request), selectionState(request),
        error, rejectable,
        {id: request.id, state: "working", actions: []},
        {id: request.id, state: "authenticating", actions: []},
        {id: request.id, state: "missing", actions: []},
    ]) {
        assert.equal(harness.call("isRenderableApprovalState", state, request), true);
    }
    assert.equal(harness.call("shouldPollApprovalState", error), false);
    assert.equal(harness.call("canRejectApprovalState", error), false);
    assert.equal(harness.call("canRejectApprovalState", rejectable), true);
    assert.equal(harness.call("canSubmitDecision", "approveRequest", rejectable), false);
    for (const invalid of [
        {...error, actions: undefined}, {...error, actions: ["approve"]},
        {...error, actions: ["retry", "reject"]}, {...error, review: messageState(request).review},
        {...error, canReject: true}, {...error, extra: true},
        {...messageState(request), review: undefined},
        {...messageState(request), actions: ["reject", "reject"]},
        {...messageState(request), actions: ["editTransaction"]},
        {...messageState(request), actions: ["unknown"]},
        {...messageState(request), state: "working", actions: []},
        {id: request.id, state: "working", actions: ["reject"]},
    ]) {
        assert.equal(harness.call("isRenderableApprovalState", invalid, request), false);
    }
});

function extractedFunction(name) {
    let start = source.indexOf(`async function ${name}(`);
    if (start === -1) { start = source.indexOf(`function ${name}(`); }
    assert.notEqual(start, -1);
    const bodyStart = source.indexOf(") {", start) + 2;
    let depth = 0;
    for (let index = bodyStart; index < source.length; index += 1) {
        if (source[index] === "{") { depth += 1; }
        if (source[index] === "}") {
            depth -= 1;
            if (depth === 0) {
                return source.slice(start, index + 1);
            }
        }
    }
    throw new Error(`unterminated ${name}`);
}

const updateProbeTimeout = Symbol("timeout");
const updateProbeNonce = "00000001000000020000000300000004";

function updateRecoveryProbeHarness({
    incognito = false,
    permission = true,
    permissionsAvailable = true,
    response,
} = {}) {
    const messages = [];
    const permissionQueries = [];
    const tab = {
        id: 7,
        configurationKey: "https://wallet.example",
        incognito,
        url: "https://wallet.example/dapp",
    };
    const browser = {
        tabs: {sendMessage(id, message) {
            messages.push({id, message});
            if (response instanceof Error) { return Promise.reject(response); }
            return response === updateProbeTimeout
                ? updateProbeTimeout
                : Promise.resolve(typeof response === "function"
                    ? response(message)
                    : response);
        }},
    };
    if (permissionsAvailable) {
        browser.permissions = {contains(query) {
            permissionQueries.push(query);
            return permission instanceof Error
                ? Promise.reject(permission)
                : Promise.resolve(permission);
        }};
    }
    const context = {
        BUILD_VERSION: packagedBuildVersion,
        WORKFLOW_VERSION: 3,
        URL,
        browser,
        genPrivateToken: () => updateProbeNonce,
        hasExactKeys: (value, keys) => value !== null &&
            typeof value === "object" &&
            Object.keys(value).length === keys.length &&
            keys.every(key => Object.hasOwn(value, key)),
        async settleExtensionMessage(pending) {
            if (pending === updateProbeTimeout) { return {status: "timeout"}; }
            try { return {response: await pending, status: "response"}; }
            catch { return {status: "failure"}; }
        },
    };
    vm.createContext(context);
    context.updateRecoveryTabFor = vm.runInContext(
        `(${extractedFunction("updateRecoveryTabFor")})`,
        context
    );
    return {
        context,
        messages,
        permissionQueries,
        tab,
    };
}

test("update recovery checks the exact content build response", async () => {
    const current = updateRecoveryProbeHarness({response: {
        buildVersion: packagedBuildVersion,
        nonce: updateProbeNonce,
        subject: "workflowProbe",
        workflowVersion: 3,
    }});
    assert.equal(await current.context.updateRecoveryTabFor(current.tab), null);
    assert.deepEqual(JSON.parse(JSON.stringify(current.messages)), [{
        id: 7,
        message: {
            nonce: updateProbeNonce,
            subject: "workflowProbe",
            workflowVersion: 3,
        },
    }]);
    assert.deepEqual(JSON.parse(JSON.stringify(current.permissionQueries)), [{
        origins: ["https://wallet.example/*"],
    }]);

    const oldBuild = updateRecoveryProbeHarness({response: {
        buildVersion: previousBuildVersion,
        nonce: updateProbeNonce,
        subject: "workflowProbe",
        workflowVersion: 3,
    }});
    assert.equal(
        await oldBuild.context.updateRecoveryTabFor(oldBuild.tab),
        oldBuild.tab
    );

    for (const response of [undefined, updateProbeTimeout]) {
        const old = updateRecoveryProbeHarness({response});
        assert.equal(
            await old.context.updateRecoveryTabFor(old.tab),
            old.tab
        );
    }

    for (const response of [
        {
            buildVersion: previousBuildVersion,
            nonce: "00000005000000060000000700000008",
            subject: "workflowProbe",
            workflowVersion: 3,
        },
        {
            buildVersion: previousBuildVersion,
            nonce: updateProbeNonce,
            subject: "workflowProbe",
            workflowVersion: 3,
            extra: true,
        },
    ]) {
        const forged = updateRecoveryProbeHarness({response});
        assert.equal(await forged.context.updateRecoveryTabFor(forged.tab), null);
    }
});

test("update recovery ignores private, denied, and receiverless tabs", async () => {
    const privateTab = updateRecoveryProbeHarness({incognito: true});
    assert.equal(await privateTab.context.updateRecoveryTabFor(privateTab.tab), null);
    assert.deepEqual(privateTab.messages, []);

    for (const permission of [false, new Error("permission check failed")]) {
        const denied = updateRecoveryProbeHarness({permission});
        assert.equal(await denied.context.updateRecoveryTabFor(denied.tab), null);
        assert.deepEqual(denied.messages, []);
    }

    const receiverless = updateRecoveryProbeHarness({
        response: new Error("no receiver"),
    });
    assert.equal(
        await receiverless.context.updateRecoveryTabFor(receiverless.tab),
        null
    );
});

function idleRecoveryRefreshHarness(reload, options = {}) {
    const button = {disabled: false};
    const hidden = new Map;
    const probes = [];
    const reloaded = [];
    let closed = 0;
    let refreshes = 0;
    let rendered = 0;
    const texts = new Map;
    const recoveryTab = {
        configurationKey: "https://wallet.example",
        id: 7,
        incognito: false,
        url: "https://wallet.example/dapp",
    };
    const currentTab = Object.hasOwn(options, "currentTab")
        ? options.currentTab
        : recoveryTab;
    const probeResult = Object.hasOwn(options, "probeResult")
        ? options.probeResult
        : recoveryTab;
    let activeTabLookup = 0;
    const context = {
        browser: {tabs: {reload(id) {
            reloaded.push(id);
            return reload();
        }}},
        isCurrentIdlePresentation: () => true,
        currentActiveTab: async () => {
            activeTabLookup += 1;
            return currentTab;
        },
        document: {getElementById: () => button},
        hide() {},
        localized: (_, fallback) => fallback,
        queueTab: {
            activeTab: recoveryTab,
            items: [],
            refreshGeneration: 4,
            refreshInFlight: null,
            refreshRequested: false,
            refreshTimer: null,
            snapshotStatus: "empty",
            updateRecoveryTab: recoveryTab,
        },
        refreshQueue: async () => { refreshes += 1; },
        renderIdleSwitchControls: () => { rendered += 1; },
        setHidden: (id, value) => hidden.set(id, value),
        setText: (id, value) => texts.set(id, value),
        show() {},
        async settleExtensionMessage(pending) {
            try { return {response: await pending, status: "response"}; }
            catch { return {status: "failure"}; }
        },
        updateRecoveryTabFor: async tab => {
            probes.push(tab);
            options.onProbe?.(context);
            return probeResult;
        },
        window: {close: () => { closed += 1; }},
    };
    vm.createContext(context);
    context.sameUpdateRecoveryTab = vm.runInContext(
        `(${extractedFunction("sameUpdateRecoveryTab")})`, context
    );
    context.shouldShowUpdateRecovery = vm.runInContext(
        `(${extractedFunction("shouldShowUpdateRecovery")})`, context
    );
    context.refreshIdleStatus = vm.runInContext(
        `(${extractedFunction("refreshIdleStatus")})`, context
    );
    return {
        button,
        closed: () => closed,
        context,
        hidden,
        lookups: () => activeTabLookup,
        probes,
        recoveryTab,
        refreshes: () => refreshes,
        reloaded,
        rendered: () => rendered,
        texts,
    };
}

test("update recovery reloads only the active tab on explicit Refresh", async () => {
    const success = idleRecoveryRefreshHarness(() => Promise.resolve());
    await success.context.refreshIdleStatus();
    assert.deepEqual(success.reloaded, [7]);
    assert.deepEqual(success.probes, [success.recoveryTab]);
    assert.equal(success.lookups(), 1);
    assert.equal(success.closed(), 1);

    const failure = idleRecoveryRefreshHarness(() => Promise.reject(
        new Error("reload failed")
    ));
    await failure.context.refreshIdleStatus();
    assert.deepEqual(failure.reloaded, [7]);
    assert.equal(failure.lookups(), 1);
    assert.equal(failure.closed(), 0);
    assert.equal(failure.button.disabled, false);
    assert.equal(failure.rendered(), 1);
    assert.equal(failure.hidden.get("idle-check-status"), false);
    assert.equal(failure.texts.get("idle-connection"), "Failed to load");

    const unknownQueue = idleRecoveryRefreshHarness(() => Promise.resolve());
    unknownQueue.context.queueTab.snapshotStatus = "unknown";
    await unknownQueue.context.refreshIdleStatus();
    assert.deepEqual(unknownQueue.reloaded, []);
    assert.deepEqual(unknownQueue.probes, []);
    assert.equal(unknownQueue.lookups(), 0);
    assert.equal(unknownQueue.refreshes(), 1);
});

test("update recovery requires the exact stored tab identity at click", async () => {
    const base = {
        configurationKey: "https://wallet.example",
        id: 7,
        incognito: false,
        url: "https://wallet.example/dapp",
    };
    for (const currentTab of [
        {...base, id: 8},
        {...base, incognito: true},
        {...base, configurationKey: "https://other.example"},
        {...base, url: "https://wallet.example/after-navigation"},
    ]) {
        const changed = idleRecoveryRefreshHarness(
            () => Promise.resolve(),
            {currentTab}
        );
        await changed.context.refreshIdleStatus();
        assert.deepEqual(changed.reloaded, []);
        assert.deepEqual(changed.probes, []);
        assert.equal(changed.lookups(), 1);
        assert.equal(changed.refreshes(), 1);
        assert.equal(changed.context.queueTab.activeTab, currentTab);
        assert.equal(changed.context.queueTab.updateRecoveryTab, null);
    }
});

test("update recovery clears a candidate that now answers with this build", async () => {
    const recovered = idleRecoveryRefreshHarness(
        () => Promise.resolve(),
        {probeResult: null}
    );
    await recovered.context.refreshIdleStatus();
    assert.deepEqual(recovered.reloaded, []);
    assert.deepEqual(recovered.probes, [recovered.recoveryTab]);
    assert.equal(recovered.refreshes(), 1);
    assert.equal(recovered.context.queueTab.updateRecoveryTab, null);
    assert.equal(recovered.button.disabled, false);
});

test("queue notifications win the click probe without clearing recovery", async () => {
    const raced = idleRecoveryRefreshHarness(
        () => Promise.resolve(),
        {
            probeResult: null,
            onProbe(context) {
                context.queueTab.refreshGeneration += 1;
                context.queueTab.refreshRequested = true;
                context.queueTab.snapshotStatus = "unknown";
            },
        }
    );
    await raced.context.refreshIdleStatus();
    assert.deepEqual(raced.reloaded, []);
    assert.equal(raced.lookups(), 1);
    assert.deepEqual(raced.probes, [raced.recoveryTab]);
    assert.equal(raced.context.queueTab.updateRecoveryTab, raced.recoveryTab);
    assert.equal(raced.refreshes(), 1);
});

test("completed-response apply uses the exact worker contract", async () => {
    const messages = [];
    let workerResponse = {applied: true};
    const request = {
        id: 7,
        host: "wallet.example",
        configurationKey: "https://wallet.example",
        requestToken: "request",
        revisions: {ethereum: 3, solana: 5},
    };
    const context = {
        WORKFLOW_VERSION: 3,
        browser: {runtime: {sendMessage(message) {
            messages.push(message);
            return Promise.resolve(workerResponse);
        }}},
        hasExactKeys: (value, keys) => value !== null &&
            typeof value === "object" &&
            Object.keys(value).length === keys.length &&
            keys.every(key => Object.hasOwn(value, key)),
        settleExtensionMessage: async pending => ({
            response: await pending,
            status: "response",
        }),
    };
    vm.createContext(context);
    const applyCompletedResponse = vm.runInContext(
        `(${extractedFunction("applyCompletedResponse")})`,
        context
    );

    assert.equal(await applyCompletedResponse(request), "applied");
    workerResponse = {id: 7, missing: true};
    assert.equal(await applyCompletedResponse(request), "missing");
    workerResponse = {id: 8, missing: true};
    assert.equal(await applyCompletedResponse(request), "failure");
    assert.deepEqual(JSON.parse(JSON.stringify(messages[0])), {
        subject: "applyCompletedResponse",
        id: 7,
        host: "wallet.example",
        configurationKey: "https://wallet.example",
        requestToken: "request",
        revisions: {ethereum: 3, solana: 5},
        workflowVersion: 3,
    });
});

function recoveredQueueHarness({
    failedID = null,
    includeCompletions = true,
    missingID = null,
} = {}) {
    const completedResponses = includeCompletions ? [
        {
            id: 1,
            host: "wallet.example",
            configurationKey: "https://wallet.example",
            requestToken: "first",
            revisions: {ethereum: 0, solana: 0},
        },
        {
            id: 2,
            host: "wallet.example",
            configurationKey: "https://wallet.example",
            requestToken: "second",
            revisions: {ethereum: 1, solana: 0},
        },
    ] : [];
    let remainingResponses = completedResponses;
    const pending = {id: 3};
    let resolveFirst;
    const firstApply = new Promise(resolve => { resolveFirst = resolve; });
    const applied = [];
    const notified = [];
    const shown = [];
    const context = {
        applyCompletedResponse: async response => {
            applied.push(response.id);
            const result = response.id === 1 ? await firstApply
                : response.id === failedID ? "failure"
                : response.id === missingID ? "missing" : "applied";
            if (result !== "failure") {
                remainingResponses = remainingResponses.filter(item => item.id !== response.id);
            }
            return result;
        },
        applyLayoutDirection: () => {},
        applyStrings: () => {},
        genId: () => 99,
        notifyResponseReadyIds: ids => { notified.push(...ids); },
        parsePendingResponse: value => value,
        queueTab: {refreshGeneration: 0, refreshRequested: false},
        scheduleNativeMessage: () => ({result: Promise.resolve({
            status: "response",
            response: {completedResponses: remainingResponses, requests: [pending]},
        })}),
        shouldDeferQueueRefreshForCurrentRequest: () => false,
        showQueue: requests => { shown.push(requests); },
    };
    vm.createContext(context);
    context.fetchPendingResponse = vm.runInContext(
        `(${extractedFunction("fetchPendingResponse")})`,
        context
    );
    context.performQueueRefresh = vm.runInContext(
        `(${extractedFunction("performQueueRefresh")})`,
        context
    );
    return {applied, context, notified, pending, resolveFirst, shown};
}

test("recovered completions apply in FIFO order before rendering queued work", async () => {
    const harness = recoveredQueueHarness();
    const refresh = harness.context.performQueueRefresh();
    for (let index = 0; index < 5; index += 1) { await Promise.resolve(); }
    assert.equal(harness.applied.join(","), "1");
    assert.deepEqual(harness.shown, []);

    harness.resolveFirst("applied");
    await refresh;
    assert.equal(harness.applied.join(","), "1,2");
    assert.deepEqual(harness.notified, [1, 2]);
    assert.deepEqual(harness.shown, [[harness.pending]]);
});

test("a failed recovered completion keeps the queue in failed-load state", async () => {
    const harness = recoveredQueueHarness({failedID: 2});
    const refresh = harness.context.performQueueRefresh();
    await Promise.resolve();
    harness.resolveFirst("applied");
    await refresh;
    assert.equal(harness.applied.join(","), "1,2");
    assert.deepEqual(harness.notified, [1]);
    assert.deepEqual(harness.shown, [null]);
});

test("an absent missing response disappears through authoritative queue refresh", async () => {
    const harness = recoveredQueueHarness({includeCompletions: false});
    await harness.context.performQueueRefresh();
    assert.deepEqual(harness.applied, []);
    assert.deepEqual(harness.notified, []);
    assert.deepEqual(harness.shown, [[harness.pending]]);
});

test("an evicted recovered completion is skipped without hiding queued work", async () => {
    const harness = recoveredQueueHarness({missingID: 2});
    const refresh = harness.context.performQueueRefresh();
    await Promise.resolve();
    harness.resolveFirst("applied");
    await refresh;
    assert.deepEqual(harness.applied, [1, 2]);
    assert.deepEqual(harness.notified, [1]);
    assert.deepEqual(harness.shown, [[harness.pending]]);
});

test("a reopened popup drains every outstanding completion across batches", async () => {
    const completions = Array.from({length: 33}, (_, index) => ({
        id: index + 1,
        host: "wallet.example",
        configurationKey: "https://wallet.example",
        requestToken: `00000000-0000-4000-8000-${String(index + 1).padStart(12, "0")}`,
        revisions: {ethereum: 0, solana: 0},
    }));
    let outstanding = completions.slice();
    const pending = {id: 99};
    function openPopup(failedID = null) {
        const applied = [];
        const pageSizes = [];
        const context = {
            applyCompletedResponse: async response => {
                if (response.id === failedID) { return "failure"; }
                applied.push(response.id);
                outstanding = outstanding.filter(item => item.id !== response.id);
                return "applied";
            },
            applyLayoutDirection: () => {},
            applyStrings: () => {},
            genId: () => 100,
            notifyResponseReadyIds: () => {},
            parsePendingResponse: value => value,
            scheduleNativeMessage: (_channel, subject) => {
                assert.equal(subject, "getPendingRequests");
                const completedResponses = outstanding.slice(0, 16);
                pageSizes.push(completedResponses.length);
                return {result: Promise.resolve({
                    status: "response",
                    response: {completedResponses, requests: [pending]},
                })};
            },
        };
        vm.createContext(context);
        context.fetchPendingResponse = vm.runInContext(
            `(${extractedFunction("fetchPendingResponse")})`, context
        );
        return {applied, pageSizes, context};
    }

    const first = openPopup(17);
    assert.equal(await first.context.fetchPendingResponse(), null);
    assert.deepEqual(first.applied, completions.slice(0, 16).map(item => item.id));
    assert.equal(outstanding[0].id, 17);

    const reopened = openPopup();
    const response = await reopened.context.fetchPendingResponse();
    assert.deepEqual(reopened.applied, completions.slice(16).map(item => item.id));
    assert.deepEqual(reopened.pageSizes, [16, 1, 0]);
    assert.deepEqual(response.requests, [pending]);
    assert.deepEqual(outstanding, []);
});

function queueNotificationHarness(fetchPendingResponse) {
    const rendered = [];
    const timers = [];
    const elements = {
        "idle-switch-account": {disabled: false},
        "screen-idle": {classList: {contains: () => false}},
        "screen-request": {classList: {contains: () => true}},
    };
    const context = {
        document: {getElementById: id => elements[id]},
        fetchPendingResponse,
        isPendingRequestAvailable: request => request?.subject ===
            "pendingRequestAvailable" && request.workflowVersion === 3 &&
            Object.keys(request).length === 2,
        queueTab: {
            booting: false,
            domReady: true,
            index: 0,
            items: [],
            refreshGeneration: 0,
            refreshInFlight: null,
            refreshRequested: false,
            refreshTimer: null,
            snapshotStatus: "empty",
        },
        renderIdleSwitchControls() {},
        setTimeout(callback, delay) {
            const timer = {callback, delay};
            timers.push(timer);
            return timer;
        },
        shouldDeferQueueRefreshForCurrentRequest: () => false,
        showQueue(requests) {
            rendered.push(requests);
            context.queueTab.items = requests ?? [];
            context.queueTab.snapshotStatus = requests?.length ? "nonempty" : "empty";
        },
        currentRequestController: null,
    };
    vm.createContext(context);
    for (const name of [
        "requestPendingQueueRefresh",
        "schedulePendingQueueRefresh",
        "handlePopupRuntimeMessage",
        "performQueueRefresh",
        "refreshQueue",
    ]) {
        context[name] = vm.runInContext(`(${extractedFunction(name)})`, context);
    }
    return {context, rendered, timers};
}

test("a pending-request notification refreshes an already-open idle popup", async () => {
    const request = {id: 60};
    const harness = queueNotificationHarness(async () => ({
        completedResponses: [],
        requests: [request],
    }));
    harness.context.handlePopupRuntimeMessage({
        subject: "pendingRequestAvailable",
        workflowVersion: 3,
    });
    assert.equal(harness.timers.length, 1);
    assert.equal(harness.timers[0].delay, 0);
    harness.timers[0].callback();
    await harness.context.queueTab.refreshInFlight;
    assert.deepEqual(harness.rendered, [[request]]);
    assert.deepEqual(harness.context.queueTab.items, [request]);
});

test("a pending-request notification fences a stale initial empty queue", async () => {
    let resolveInitial;
    const initial = new Promise(resolve => { resolveInitial = resolve; });
    const request = {id: 61};
    let reads = 0;
    const harness = queueNotificationHarness(() => ++reads === 1
        ? initial
        : Promise.resolve({completedResponses: [], requests: [request]}));
    const bootRefresh = harness.context.refreshQueue();
    await Promise.resolve();
    harness.context.handlePopupRuntimeMessage({
        subject: "pendingRequestAvailable",
        workflowVersion: 3,
    });
    resolveInitial({completedResponses: [], requests: []});
    await bootRefresh;
    assert.equal(reads, 2);
    assert.deepEqual(harness.rendered, [[request]]);
});

function manualSwitchHarness(sendMessage) {
    const button = { disabled: false };
    const sent = [];
    const timeouts = [];
    let refreshes = 0;
    let controlRenders = 0;
    let connectionText = null;
    const context = {
        URL,
        MANUAL_SWITCH_TIMEOUT: 10_000,
        WORKFLOW_VERSION: 3,
        browser: { tabs: { sendMessage: async (tabID, message) => {
            sent.push({ tabID, message });
            return sendMessage(sent.length, message);
        } } },
        currentPrivateBrowsing: () => false,
        isCurrentIdlePresentation: () => true,
        localized: (_, fallback) => fallback,
        queueTab: {
            activeTab: {
                id: 7,
                configurationKey: "https://wallet.example",
                incognito: false,
            },
            contentScriptUnavailableTab: null,
        },
        sameTab: (left, right) => left?.id === right?.id &&
            left?.configurationKey === right?.configurationKey,
        settleExtensionMessage: async (pending, milliseconds) => {
            timeouts.push(milliseconds);
            try { return { status: "response", response: await pending }; }
            catch { return { status: "failure" }; }
        },
        document: { getElementById: id => id === "idle-switch-account" ? button : {} },
        setText: (_id, value) => { connectionText = value; },
        hide: () => {},
        show: () => {},
        renderIdleSwitchControls: () => { controlRenders += 1; },
        refreshQueue: async () => { refreshes += 1; },
    };
    vm.createContext(context);
    new vm.Script(wireSource).runInContext(context);
    context.switchAccountFromIdle = vm.runInContext(
        `(${extractedFunction("switchAccountFromIdle")})`,
        context
    );
    return {
        button,
        context,
        sent,
        timeouts,
        connectionText: () => connectionText,
        controlRenders: () => controlRenders,
        refreshes: () => refreshes,
    };
}

test("manual Switch Account sends one exact stateless intent", async () => {
    const status = {
        approvalRequired: true,
        configurationKey: "https://wallet.example",
        id: 41,
        requestToken: "00000000-0000-0000-0000-000000000001",
        revisions: {ethereum: 0, solana: 0},
        subject: "manualSwitchAcknowledged",
        workflowVersion: 3,
    };
    const harness = manualSwitchHarness(async () => status);
    await harness.context.switchAccountFromIdle();

    assert.deepEqual(JSON.parse(JSON.stringify(harness.sent)), [{
        tabID: 7,
        message: {
            configurationKey: "https://wallet.example",
            subject: "manualSwitchIntent",
            workflowVersion: 3,
        },
    }]);
    assert.equal(harness.refreshes(), 1);
    assert.equal(harness.button.disabled, true);
    assert.deepEqual(harness.timeouts, [10_000]);
});

test("manual Switch Account accepts canonical native handles and terminal responses", async () => {
    const responses = [
        {
            approvalRequired: false,
            configurationKey: "https://wallet.example",
            id: 17,
            requestToken: "00000000-0000-0000-0000-000000000002",
            revisions: {ethereum: 3, solana: 2},
            subject: "manualSwitchAcknowledged",
            workflowVersion: 3,
        },
        {
            approvalRequired: true,
            configurationKey: "https://wallet.example",
            id: 41,
            requestToken: "00000000-0000-0000-0000-000000000001",
            revisions: {ethereum: 0, solana: 0},
            subject: "manualSwitchAcknowledged",
            workflowVersion: 3,
        },
        {
            id: 41,
            name: "switchAccount",
            provider: "unknown",
            error: "Canceled",
            errorCode: 4001,
        },
    ];
    for (const response of responses) {
        const harness = manualSwitchHarness(async () => response);
        await harness.context.switchAccountFromIdle();
        assert.equal(harness.refreshes(), 1);
        assert.equal(harness.controlRenders(), 0);
    }
});

test("manual Switch Account rejects undefined malformed and cross-key replies", async () => {
    const invalid = [
        undefined,
        {id: 41, name: "switchAccount"},
        {
            admissionDeadline: Date.now() + 60_000,
            configurationKey: "https://wallet.example",
            id: 41,
            subject: "manualSwitchInFlight",
            workflowVersion: 3,
        },
        {
            approvalRequired: true,
            configurationKey: "https://other.example",
            id: 41,
            requestToken: "00000000-0000-0000-0000-000000000001",
            revisions: {ethereum: 0, solana: 0},
            subject: "manualSwitchAcknowledged",
            workflowVersion: 3,
        },
        {
            approvalRequired: true,
            configurationKey: "https://wallet.example",
            id: "41",
            requestToken: "00000000-0000-0000-0000-000000000001",
            revisions: {ethereum: 0, solana: 0},
            subject: "manualSwitchAcknowledged",
            workflowVersion: 3,
        },
    ];
    for (const response of invalid) {
        const harness = manualSwitchHarness(async () => response);
        await harness.context.switchAccountFromIdle();
        assert.equal(harness.button.disabled, false);
        assert.equal(harness.refreshes(), 0);
        assert.equal(harness.controlRenders(), 1);
        assert.equal(harness.connectionText(), "Failed to load");
    }
});

test("manual Switch Account repeats the same intent after transport failure", async () => {
    const status = {
        approvalRequired: true,
        configurationKey: "https://wallet.example",
        id: 41,
        requestToken: "00000000-0000-0000-0000-000000000001",
        revisions: {ethereum: 0, solana: 0},
        subject: "manualSwitchAcknowledged",
        workflowVersion: 3,
    };
    const harness = manualSwitchHarness(async attempt => {
        if (attempt === 1) { throw new Error("unavailable"); }
        return status;
    });
    await harness.context.switchAccountFromIdle();
    assert.equal(harness.button.disabled, false);
    assert.equal(
        harness.context.queueTab.contentScriptUnavailableTab,
        harness.context.queueTab.activeTab
    );
    await harness.context.switchAccountFromIdle();

    assert.equal(harness.sent.length, 2);
    assert.deepEqual(harness.sent[0].message, harness.sent[1].message);
    assert.equal(harness.context.queueTab.contentScriptUnavailableTab, null);
    assert.equal(harness.refreshes(), 1);
});

for (const recovery of ["queue failure", "extension update"]) {
    test(`queue refresh preserves Refresh after ${recovery}`, async () => {
        const elements = new Map;
        let queueFails = recovery === "queue failure";
        const document = {
            documentElement: popupElement("document-element"),
            addEventListener() {},
            querySelectorAll: () => [],
            getElementById(id) {
                if (!elements.has(id)) { elements.set(id, popupElement(id)); }
                return elements.get(id);
            },
        };
        const context = vm.createContext({
            URL,
            document,
            navigator: {maxTouchPoints: 5},
            setTimeout: () => 1,
            clearTimeout() {},
            browser: {
                extension: {inIncognitoContext: false},
                runtime: {
                    async sendNativeMessage() {
                        if (queueFails) { throw new Error("Native unavailable"); }
                        return {requests: [], completedResponses: []};
                    },
                    sendMessage: async () => ({
                        latestConfigurations: [],
                        revisions: {ethereum: 0, solana: 0},
                    }),
                },
            },
        });
        new vm.Script(wireSource).runInContext(context);
        new vm.Script(source).runInContext(context);
        vm.runInContext(`
            queueTab.domReady = true;
            queueTab.booting = false;
            queueTab.activeTab = {
                id: 3,
                host: "wallet.example",
                configurationKey: "https://wallet.example",
                incognito: false,
            };
        `, context);
        if (recovery === "extension update") {
            vm.runInContext("queueTab.updateRecoveryTab = queueTab.activeTab", context);
        }

        await vm.runInContext("refreshQueue()", context);

        const refresh = document.getElementById("idle-check-status");
        assert.equal(document.getElementById("idle-connection").textContent, "Failed to load");
        assert.equal(refresh.classList.contains("hidden"), false);
        assert.equal(refresh.disabled, false);
        assert.equal(document.getElementById("idle-switch-account").disabled, true);

        queueFails = false;
        vm.runInContext("queueTab.updateRecoveryTab = null", context);
        await vm.runInContext("refreshQueue()", context);

        assert.equal(refresh.classList.contains("hidden"), true);
        assert.equal(document.getElementById("idle-switch-account").disabled, false);
    });
}

function requestToken(value) {
    return `00000000-0000-0000-0000-${String(value).padStart(12, "0")}`;
}

function pendingRequest(id = 7, token = 1) {
    return {
        configurationKey: "https://wallet.example",
        host: "wallet.example",
        id,
        provider: "ethereum",
        receivedAt: Date.now(),
        requestToken: requestToken(token),
        revisions: {ethereum: 0, solana: 0},
        sequence: 0,
    };
}

function messageState(request = pendingRequest(), overrides = {}, envelope = {}) {
    return {
        host: request.host,
        id: request.id,
        state: "review",
        actions: ["approve", "reject"],
        review: {
            account: {name: "Primary", croppedAddress: "0x1234"},
            kind: "signMessage",
            meta: "Hello from the dapp",
            reviewToken: requestToken(101),
            title: "Sign message",
            ...overrides,
        },
        ...envelope,
    };
}

function selectionState(request = pendingRequest(), overrides = {}, envelope = {}) {
    return {
        host: request.host,
        id: request.id,
        state: "review",
        actions: ["approve", "reject"],
        review: {
            accounts: [{
                name: "Primary",
                croppedAddress: "1111…1111",
                walletId: "wallet",
                address: "11111111111111111111111111111111",
                coin: "solana",
                derivationPath: "m/44'/501'/0'",
                isSelected: true,
            }],
            allowsEmptySelection: false,
            canSelectNetwork: false,
            kind: "selectAccount",
            reviewToken: requestToken(101),
            title: "Connect",
            ...overrides,
        },
        ...envelope,
    };
}

function transactionState(request = pendingRequest(), overrides = {}, envelope = {}) {
    return {
        host: request.host,
        id: request.id,
        state: "review",
        actions: ["approve", "reject", "editTransaction", "setTransactionSpeed",
            ...(overrides.alert ? ["resolveApprovalAlert"] : [])],
        review: {
            account: {name: "Primary", croppedAddress: "0x1234"},
            editor: {
                gasPriceGwei: "2",
                nonce: "1",
                suggestedGasPriceGwei: "3",
                usesEIP1559: false,
            },
            feeLines: ["Network fee: 0.001 ETH"],
            kind: "sendTransaction",
            networkName: "Ethereum",
            phase: "ready",
            reviewToken: requestToken(101),
            slider: {maximum: 200, position: 100, visible: true},
            title: "Send transaction",
            ...overrides,
        },
        ...envelope,
    };
}

async function flushPopup() {
    for (let index = 0; index < 3; index += 1) {
        await new Promise(resolve => setImmediate(resolve));
    }
}

function popupHarness(options = {}) {
    const nativeMessages = [];
    const workerMessages = [];
    const tabMessages = [];
    const focusCalls = [];
    const textWrites = [];
    const elements = new Map;
    const documentListeners = new Map;
    const runtimeListeners = [];
    const timers = new Map;
    const timerHistory = [];
    const states = new Map;
    const handlers = {
        native: options.native,
        worker: options.worker,
        tab: options.tab,
    };
    const model = {
        closed: 0,
        completed: [],
        requests: options.requests || [],
        updateRecovery: options.updateRecovery === true,
    };
    let nextTimer = 0;
    let nextElement = 0;
    let randomValue = 0;
    const tab = {
        id: 3,
        incognito: false,
        url: "https://wallet.example/path",
    };
    let document;
    function element(id) {
        const classes = new Set(id === "screen-loading" ? [] : ["hidden"]);
        const listeners = new Map;
        let textContent = "";
        const value = {
            id,
            children: [],
            classList: {
                add: name => classes.add(name),
                contains: name => classes.has(name),
                remove: name => classes.delete(name),
            },
            dataset: {},
            disabled: false,
            inert: false,
            isConnected: true,
            open: false,
            src: "",
            textContent: "",
            value: "",
            addEventListener(name, listener) { listeners.set(name, listener); },
            appendChild(child) { this.children.push(child); return child; },
            emit(name) { return listeners.get(name)?.({target: this}); },
            focus() { document.activeElement = this; focusCalls.push(id); },
            setAttribute(name, attribute) { this[name] = attribute; },
        };
        Object.defineProperty(value, "textContent", {
            get() { return textContent; },
            set(text) { textContent = text; textWrites.push({id, text}); },
        });
        Object.defineProperty(value, "innerHTML", {
            get() { return ""; },
            set() {
                for (const child of value.children) { child.isConnected = false; }
                value.children = [];
            },
        });
        return value;
    }
    document = {
        activeElement: null,
        documentElement: element("document-element"),
        addEventListener(name, listener) { documentListeners.set(name, listener); },
        createElement: name => element(`${name}-${++nextElement}`),
        getElementById(id) {
            if (!elements.has(id)) { elements.set(id, element(id)); }
            return elements.get(id);
        },
        querySelectorAll: () => [],
    };
    const defaultNative = message => {
        if (message.subject === "getPendingRequests") {
            return {completedResponses: model.completed, requests: model.requests};
        }
        if (message.subject === "getApprovalState" || message.subject === "retryApproval") {
            return states.get(message.requestToken) || messageState({
                id: message.id, host: "wallet.example",
            });
        }
        if (message.subject === "openApp") { return {id: message.id, opened: true}; }
        return {status: "ok"};
    };
    const defaultWorker = message => {
        if (message.subject === "getLatestConfiguration") {
            return {latestConfigurations: [], revisions: {ethereum: 0, solana: 0}};
        }
        if (message.subject === "applyCompletedResponse") {
            model.completed = model.completed.filter(item =>
                item.requestToken !== message.requestToken
            );
            return {applied: true};
        }
        return {status: "ok"};
    };
    const browser = {
        extension: {inIncognitoContext: false},
        permissions: {contains: async () => true},
        runtime: {
            onMessage: {addListener(listener) { runtimeListeners.push(listener); }},
            sendMessage(message) {
                workerMessages.push(normalized(message));
                return Promise.resolve(handlers.worker
                    ? handlers.worker(message, defaultWorker)
                    : defaultWorker(message));
            },
            sendNativeMessage(application, message) {
                assert.equal(application, "org.lil.wallet");
                nativeMessages.push(normalized(message));
                return Promise.resolve(handlers.native
                    ? handlers.native(message, defaultNative)
                    : defaultNative(message));
            },
        },
        storage: {local: {get: async () => ({
            workflowUpdateRecoveryNeeded: model.updateRecovery,
        })}},
        tabs: {
            query: async () => [tab],
            sendMessage(id, message) {
                tabMessages.push({id, message: normalized(message)});
                return Promise.resolve(handlers.tab ? handlers.tab(message) : {
                    buildVersion: packagedBuildVersion,
                    nonce: message.nonce,
                    subject: "workflowProbe",
                    workflowVersion: 3,
                });
            },
        },
    };
    const context = vm.createContext({
        URL,
        browser,
        clearTimeout: id => timers.delete(id),
        crypto: {getRandomValues(values) {
            for (let index = 0; index < values.length; index += 1) {
                values[index] = ++randomValue;
            }
            return values;
        }},
        document,
        navigator: {maxTouchPoints: 5},
        setTimeout(callback, delay) {
            const timer = {callback, delay, id: ++nextTimer};
            timers.set(timer.id, timer);
            timerHistory.push(timer);
            return timer.id;
        },
        window: {close() { model.closed += 1; }},
    });
    new vm.Script(wireSource, {filename: "bridge_wire.js"}).runInContext(context);
    new vm.Script(source, {filename: "popup.js"}).runInContext(context);
    return {
        browser,
        context,
        document,
        focusCalls,
        handlers,
        model,
        nativeMessages,
        states,
        tab,
        tabMessages,
        textWrites,
        timerHistory,
        timers,
        workerMessages,
        get controller() { return vm.runInContext("currentRequestController", context); },
        get queue() { return vm.runInContext("queueTab", context); },
        get(name) { return document.getElementById(name); },
        call(name, ...arguments_) { return vm.runInContext(name, context)(...arguments_); },
        setState(request, state) { states.set(request.requestToken, state); },
        async boot() {
            documentListeners.get("DOMContentLoaded")();
            await flushPopup();
        },
        async show(requests) {
            model.requests = requests;
            this.call("showQueue", requests);
            await flushPopup();
            return this.controller;
        },
        async fire(id) {
            const timer = timers.get(id);
            assert.ok(timer, `Expected live timer ${id}`);
            timers.delete(id);
            timer.callback();
            await flushPopup();
        },
        notify() {
            for (const listener of runtimeListeners) {
                listener({subject: "pendingRequestAvailable", workflowVersion: 3});
            }
        },
        clearMessages() {
            nativeMessages.length = 0;
            workerMessages.length = 0;
            tabMessages.length = 0;
        },
        visibleSnapshot() {
            return [...elements].map(([id, item]) => ({
                id,
                text: item.textContent,
                value: item.value,
                disabled: item.disabled,
                hidden: item.classList.contains("hidden"),
                inert: item.inert,
                open: item.open,
                children: item.children.map(child => [child.id, child.textContent]),
            }));
        },
    };
}

async function reviewedPopup(stateFor = messageState) {
    const request = pendingRequest();
    const harness = popupHarness({requests: [request]});
    harness.setState(request, stateFor(request));
    await harness.boot();
    harness.clearMessages();
    return harness;
}

test("full popup boot renders FIFO requests through the production controller", async () => {
    const first = pendingRequest(9, 1);
    const second = {...pendingRequest(1, 2), sequence: 1};
    const harness = popupHarness({requests: [first, second]});
    harness.setState(first, messageState(first));
    harness.setState(second, messageState(second, {title: "Second request"}));

    await harness.boot();

    assert.equal(harness.controller.constructor.name, "PopupRequestController");
    assert.equal(harness.controller.request.requestToken, first.requestToken);
    assert.equal(harness.get("queue-indicator").textContent, "1 of 2");
    assert.equal(harness.get("request-title").textContent, "Sign message");
    assert.equal(harness.get("section-message").classList.contains("hidden"), false);
    assert.equal(harness.get("working-overlay").classList.contains("hidden"), true);
    assert.deepEqual(harness.nativeMessages.map(message => message.subject), [
        "getPendingRequests", "getApprovalState",
    ]);
    assert.ok(harness.nativeMessages.every(message => message.__bwPrivateBrowsing === false));
});

test("approval reviews omit malformed images without changing approval content or source responses", async () => {
    const request = pendingRequest();
    for (const original of [messageState(request), transactionState(request), selectionState(request)]) {
        for (const image of [null, false, 7, {}, []]) {
            const response = {
                ...original,
                review: Object.freeze({
                    ...original.review,
                    iconURL: image,
                    ...(original.review.account ? {account: Object.freeze({...original.review.account, icon: image})} : {}),
                    ...(original.review.accounts ? {
                        accounts: Object.freeze(original.review.accounts.map(account => Object.freeze({...account, icon: image}))),
                    } : {}),
                }),
            };
            Object.freeze(response);
            const before = normalized(response);
            const harness = popupHarness({requests: [request]});
            harness.setState(request, response);

            await harness.boot();

            assert.deepEqual(normalized(harness.controller.state), original);
            assert.equal(harness.get("request-favicon").classList.contains("hidden"), true);
            assert.equal(harness.get("button-approve").disabled, false);
            assert.deepEqual(normalized(response), before);
        }
    }
});

test("valid and absent approval images retain their existing rendering", async () => {
    for (const images of [{}, {iconURL: "https://wallet.example/icon.png", icon: "data:image/png;base64,aW1hZ2U="}]) {
        const request = pendingRequest();
        const response = messageState(request, {
            ...(images.iconURL ? {iconURL: images.iconURL} : {}),
            account: {name: "Primary", croppedAddress: "0x1234", ...(images.icon ? {icon: images.icon} : {})},
        });
        const harness = popupHarness({requests: [request]});
        harness.setState(request, response);

        await harness.boot();

        assert.deepEqual(normalized(harness.controller.state), response);
        assert.equal(harness.get("request-favicon").classList.contains("hidden"), !images.iconURL);
        if (images.iconURL) {
            assert.equal(harness.get("request-favicon").src, images.iconURL);
        }
        const accountImages = harness.get("signing-account").children.filter(child => child.className === "account-icon");
        assert.equal(accountImages.length, images.icon ? 1 : 0);
        if (images.icon) { assert.equal(accountImages[0].src, images.icon); }
    }
});

test("poll and transaction edit responses use the same nonfatal image normalization", async () => {
    const harness = await reviewedPopup(transactionState);
    const controller = harness.controller;
    const response = transactionState(controller.request, {
        iconURL: null,
        account: {name: "Primary", croppedAddress: "0x1234", icon: false},
        reviewToken: requestToken(102),
        valueLine: "Value: 1 ETH",
    });
    const before = normalized(response);
    harness.setState(controller.request, response);
    controller.adoptState({id: controller.request.id, state: "working", actions: []});
    controller.reconcileScheduling();

    await harness.fire(controller.followUpTimer);

    assert.equal(controller.state.state, "review");
    assert.equal(controller.state.review.reviewToken, requestToken(102));
    assert.equal(harness.get("tx-value").textContent, "Value: 1 ETH");
    assert.equal(harness.get("button-approve").disabled, false);
    const edited = {
        ...response,
        review: {
            ...response.review,
            editor: {...response.review.editor, gasPriceGwei: "3"},
            reviewToken: requestToken(103),
        },
    };
    harness.handlers.native = (message, fallback) =>
        message.subject === "applyTransactionEdits" ? edited : fallback(message);

    await harness.get("editor-suggested").emit("click");

    assert.equal(controller.state.state, "review");
    assert.equal(controller.state.review.reviewToken, requestToken(103));
    assert.equal(harness.get("edit-gas-price").value, "3");
    assert.equal(harness.get("button-approve").disabled, false);
    assert.equal(Object.hasOwn(controller.state.review, "iconURL"), false);
    assert.equal(Object.hasOwn(controller.state.review.account, "icon"), false);
    assert.deepEqual(normalized(response), before);
    assert.equal(edited.review.iconURL, null);
    assert.equal(edited.review.account.icon, false);
});

test("discarding invalid images never makes malformed approval content actionable", async () => {
    const request = pendingRequest();
    for (const response of [
        messageState(request, {}, {id: request.id + 1}),
        messageState(request, {reviewToken: "invalid"}),
        messageState(request, {account: {name: 7, croppedAddress: "0x1234", icon: null}}),
        selectionState(request, {accounts: [{...selectionState(request).review.accounts[0], address: 7, icon: null}]}),
        messageState(request, {meta: {message: "invalid"}}),
        messageState(request, {title: 7}),
        transactionState(request, {feeLines: [7]}),
        transactionState(request, {}, {actions: "approve"}),
        transactionState(request, {dataInterpretation: {call: "approve"}}),
        {id: request.id, state: "error", error: "Compact failure"},
        {id: request.id, state: "working"},
        {status: "ignored"},
        messageState(request, {kind: "unknown"}),
    ]) {
        const harness = popupHarness({requests: [request]});
        harness.setState(request, response.review
            ? {...response, review: {...response.review, iconURL: null}}
            : response);

        await harness.boot();

        assert.equal(harness.controller.state.state, "error");
        assert.equal(harness.get("request-error").textContent, "Failed to load");
        assert.equal(harness.get("button-approve").textContent, "Refresh");
        assert.equal(harness.get("button-reject").disabled, true);
        harness.clearMessages();

        await harness.get("button-approve").emit("click");

        assert.deepEqual(harness.workerMessages, []);
        assert.deepEqual(harness.nativeMessages.map(message => message.subject), ["retryApproval"]);
    }
});

test("controller approval strips caller revisions and passwords at the actual worker boundary", async () => {
    for (const kind of ["signMessage", "addChain"]) {
        const harness = await reviewedPopup(request => kind === "addChain" ? {
            id: request.id,
            host: request.host,
            state: "review",
            actions: ["approve", "reject"],
            review: {
                kind,
                reviewToken: requestToken(101),
                title: "Add network",
                chainName: "Custom",
                rpcURL: "https://rpc.example",
            },
        } : messageState(request));
        const request = harness.controller.request;

        await harness.controller.submitCurrentDecision("approveRequest", {
            password: "must-stay-local",
            revisions: {ethereum: 99, solana: 99},
        });

        assert.deepEqual(harness.nativeMessages, []);
        assert.deepEqual(harness.workerMessages, [{
            subject: "approveRequestWithCurrentRevisions",
            id: request.id,
            host: request.host,
            configurationKey: request.configurationKey,
            requestToken: request.requestToken,
            reviewToken: requestToken(101),
            payload: {},
            privateBrowsing: false,
            workflowVersion: 3,
        }]);
        assert.equal(harness.controller.followUpMode, "poll");
        assert.equal(harness.timers.get(harness.controller.followUpTimer).delay, 400);
    }
});

test("controller errors explicitly retry the visible request without entering the queue", async () => {
    const harness = await reviewedPopup();
    const controller = harness.controller;
    controller.adoptState({id: controller.request.id, state: "error", actions: ["retry"], error: "Failed"});
    assert.equal(harness.get("button-approve").disabled, false);
    assert.equal(harness.get("button-approve").textContent, "Refresh");
    assert.equal(harness.get("button-reject").disabled, true);
    assert.equal(controller.followUpTimer, null);

    await harness.get("button-approve").emit("click");

    assert.deepEqual(harness.nativeMessages, [{
        subject: "retryApproval",
        id: controller.request.id,
        workflowVersion: 3,
        requestToken: controller.request.requestToken,
        __bwPrivateBrowsing: false,
    }]);
    assert.equal(controller.state.state, "review");
    assert.equal(harness.get("working-overlay").classList.contains("hidden"), true);
});

test("rejectable errors submit tokenless Reject without a refresh", async () => {
    const harness = await reviewedPopup();
    const controller = harness.controller;
    controller.adoptState({
        id: controller.request.id,
        state: "error",
        actions: ["reject"],
        host: controller.request.host,
        error: "Too much data to display",
    });
    assert.equal(harness.get("button-approve").disabled, true);
    assert.equal(harness.get("button-reject").disabled, false);
    assert.equal(controller.followUpTimer, null);

    await harness.get("button-reject").emit("click");

    assert.deepEqual(harness.workerMessages, []);
    assert.deepEqual(harness.nativeMessages, [{
        subject: "rejectRequest",
        id: controller.request.id,
        workflowVersion: 3,
        requestToken: controller.request.requestToken,
        __bwPrivateBrowsing: false,
    }]);
    assert.equal(controller.followUpMode, "poll");
});

test("approval polling adopts an error and stops its only follow-up timer", async () => {
    const harness = await reviewedPopup();
    const controller = harness.controller;
    harness.setState(controller.request, {id: controller.request.id, state: "error", actions: ["retry"], error: "Failed"});
    controller.adoptState({id: controller.request.id, state: "working", actions: []});
    controller.reconcileScheduling();

    await harness.fire(controller.followUpTimer);

    assert.equal(controller.state.state, "error");
    assert.equal(harness.get("request-error").textContent, "Failed");
    assert.equal(harness.get("working-overlay").classList.contains("hidden"), true);
    assert.equal(controller.followUpTimer, null);
    assert.equal(harness.timers.size, 0);
});

test("the production approval lane uses the long timeout while reads remain independent", async () => {
    const harness = await reviewedPopup();
    const gate = deferred();
    harness.handlers.worker = (message, fallback) =>
        message.subject === "approveRequestWithCurrentRevisions" ? gate.promise : fallback(message);
    const controller = harness.controller;
    const approval = controller.submitCurrentDecision("approveRequest", {});
    await flushPopup();
    assert.equal(harness.workerMessages.length, 1);
    assert.ok([...harness.timers.values()].some(timer => timer.delay === 190_000));

    const queued = controller.dispatch("mutation", "applyTransactionEdits", {mode: "suggested"});
    const read = controller.dispatch("approval", "getApprovalState");
    await read;
    assert.deepEqual(harness.nativeMessages.map(message => message.subject), ["getApprovalState"]);

    gate.resolve({status: "ok"});
    await approval;
    assert.equal((await queued).status, "response");
    assert.deepEqual(harness.nativeMessages.map(message => message.subject), [
        "getApprovalState", "applyTransactionEdits",
    ]);
});

test("timed-out native actions release their real lane before raw settlement", async () => {
    const harness = await reviewedPopup();
    const gate = deferred();
    harness.handlers.native = (message, fallback) =>
        message.subject === "applyTransactionEdits" ? gate.promise : fallback(message);
    const first = harness.controller.dispatch("mutation", "applyTransactionEdits", {mode: "suggested"});
    await flushPopup();
    const second = harness.controller.dispatch("action", "rejectRequest", undefined, {reviewToken: undefined});
    await flushPopup();
    assert.deepEqual(harness.nativeMessages.map(message => message.subject), ["applyTransactionEdits"]);
    const timeout = [...harness.timers.values()].find(timer => timer.delay === 5000);

    await harness.fire(timeout.id);

    assert.equal((await first).status, "failure");
    assert.equal((await second).status, "response");
    assert.deepEqual(harness.nativeMessages.map(message => message.subject), [
        "applyTransactionEdits", "rejectRequest",
    ]);
    const beforeLateReply = harness.visibleSnapshot();
    gate.resolve({status: "ok"});
    await flushPopup();
    assert.deepEqual(harness.visibleSnapshot(), beforeLateReply);
    assert.equal(harness.timers.size, 0);
});

test("queued transport actions distinguish dispatch-time explicit and tokenless review tokens", async () => {
    for (const [options, expected] of [
        [{}, requestToken(102)],
        [{reviewToken: requestToken(101)}, requestToken(101)],
        [{reviewToken: undefined}, undefined],
    ]) {
        const harness = await reviewedPopup();
        const gate = deferred();
        harness.handlers.native = (message, fallback) =>
            message.subject === "openApp" ? gate.promise : fallback(message);
        const predecessor = harness.call("scheduleNativeMessage", "app", "openApp", 99);
        await flushPopup();
        const queued = harness.controller.dispatch("mutation", "applyTransactionEdits", {}, options);
        harness.controller.adoptState(messageState(harness.controller.request, {reviewToken: requestToken(102)}));

        gate.resolve({id: 99, opened: true});
        await predecessor.result;
        await queued;

        assert.equal(harness.nativeMessages.at(-1).subject, "applyTransactionEdits");
        assert.equal(harness.nativeMessages.at(-1).reviewToken, expected);
    }
});

test("queued approval cancels on review rotation while tokenless rejection remains valid", async () => {
    for (const subject of ["approveRequest", "rejectRequest"]) {
        const harness = await reviewedPopup();
        const controller = harness.controller;
        const gate = deferred();
        harness.handlers.native = (message, fallback) =>
            message.subject === "openApp" ? gate.promise : fallback(message);
        const predecessor = harness.call("scheduleNativeMessage", "app", "openApp", 99);
        await flushPopup();
        const decision = controller.submitCurrentDecision(subject, subject === "approveRequest" ? {} : undefined);
        await flushPopup();
        controller.adoptState(messageState(controller.request, {reviewToken: requestToken(102)}));

        gate.resolve({id: 99, opened: true});
        await predecessor.result;
        await decision;

        assert.deepEqual(harness.workerMessages, []);
        if (subject === "approveRequest") {
            assert.deepEqual(harness.nativeMessages.map(message => message.subject), ["openApp"]);
            assert.equal(controller.phase, "displaying");
            assert.equal(controller.followUpTimer, null);
        } else {
            assert.equal(harness.nativeMessages.at(-1).subject, "rejectRequest");
            assert.equal(harness.nativeMessages.at(-1).reviewToken, undefined);
            assert.equal(controller.followUpMode, "poll");
        }
        assert.equal(controller.state.review.reviewToken, requestToken(102));
    }
});

test("terminal decisions fence an older read and poll only after their native reply", async () => {
    for (const subject of ["approveRequest", "rejectRequest"]) {
        const harness = await reviewedPopup();
        const readGate = deferred();
        const actionGate = deferred();
        const controller = harness.controller;
        harness.handlers.native = (message, fallback) => {
            if (message.subject === "getApprovalState" || message.subject === "retryApproval") { return readGate.promise; }
            if (message.subject === "rejectRequest") { return actionGate.promise; }
            return fallback(message);
        };
        harness.handlers.worker = (message, fallback) =>
            message.subject === "approveRequestWithCurrentRevisions" ? actionGate.promise : fallback(message);
        const refresh = controller.readState({refresh: true});
        await flushPopup();
        const decision = controller.submitCurrentDecision(subject, subject === "approveRequest" ? {} : undefined);
        await flushPopup();
        assert.equal(controller.phase, "submitting");
        assert.equal(controller.followUpTimer, null);
        assert.equal(harness.get("working-overlay").classList.contains("hidden"), false);

        readGate.resolve(messageState(controller.request, {reviewToken: requestToken(999), title: "Stale"}));
        await refresh;

        assert.equal(controller.state.review.reviewToken, requestToken(101));
        assert.equal(harness.get("request-title").textContent, "Sign message");
        assert.equal(harness.get("working-overlay").classList.contains("hidden"), false);
        assert.equal(controller.followUpTimer, null);
        actionGate.resolve({status: "ok"});
        await decision;
        assert.equal(controller.followUpMode, "poll");
    }
});

test("replacement with the same numeric id disposes old reads actions and mutations", async () => {
    for (const operation of ["read", "approval", "mutation"]) {
        const harness = await reviewedPopup(transactionState);
        const first = harness.controller;
        const replacement = pendingRequest(first.request.id, 2);
        const gate = deferred();
        harness.handlers.native = (message, fallback) => {
            if (message.requestToken === first.request.requestToken &&
                message.subject === (operation === "read" ? "getApprovalState" : "applyTransactionEdits")) {
                return gate.promise;
            }
            return fallback(message);
        };
        harness.handlers.worker = (message, fallback) =>
            operation === "approval" && message.subject === "approveRequestWithCurrentRevisions"
                ? gate.promise : fallback(message);
        const pending = operation === "read" ? first.readState({refresh: true})
            : operation === "approval" ? first.submitCurrentDecision("approveRequest", {})
            : first.applyEdits();
        await flushPopup();
        harness.setState(replacement, transactionState(replacement, {
            title: "Replacement B", reviewToken: requestToken(202),
        }));
        await harness.show([replacement]);
        const second = harness.controller;
        const before = harness.visibleSnapshot();
        const focusCount = harness.focusCalls.length;
        const writeCount = harness.textWrites.length;

        gate.resolve(operation === "approval" ? {status: "ok"} : transactionState(first.request, {
            title: "Late A",
            reviewToken: requestToken(999),
            alert: {title: "Old alert", message: "", actions: [{title: "Cancel", action: "cancel"}]},
        }));
        await pending;
        await flushPopup();

        assert.equal(first.phase, "disposed");
        assert.equal(first.isActive, false);
        assert.equal(first.followUpTimer, null);
        assert.equal(first.tickets.size, 0);
        assert.equal(harness.controller, second);
        assert.equal(second.request.requestToken, replacement.requestToken);
        assert.equal(second.state.review.reviewToken, requestToken(202));
        assert.equal(harness.get("request-title").textContent, "Replacement B");
        assert.equal(harness.focusCalls.length, focusCount);
        assert.ok(!harness.textWrites.slice(writeCount).some(write => write.text === "Late A"));
        if (operation !== "read") { assert.deepEqual(harness.visibleSnapshot(), before); }
        assert.equal(harness.timers.size, 1);
        assert.ok(harness.timers.has(second.followUpTimer));
    }
});

test("disposing a queued approval prevents its native dispatch and preserves the replacement", async () => {
    const harness = await reviewedPopup();
    const gate = deferred();
    harness.handlers.native = (message, fallback) =>
        message.subject === "openApp" ? gate.promise : fallback(message);
    const predecessor = harness.call("scheduleNativeMessage", "app", "openApp", 99);
    await flushPopup();
    const first = harness.controller;
    const queued = first.submitCurrentDecision("approveRequest", {});
    await flushPopup();
    const replacement = pendingRequest(first.request.id, 2);
    harness.setState(replacement, messageState(replacement, {title: "Replacement B"}));
    await harness.show([replacement]);
    const second = harness.controller;
    const next = second.submitCurrentDecision("approveRequest", {});
    await flushPopup();
    assert.deepEqual(harness.workerMessages.filter(message => message.subject === "approveRequestWithCurrentRevisions"), []);

    gate.resolve({id: 99, opened: true});
    await predecessor.result;
    await queued;
    await next;

    assert.deepEqual(harness.workerMessages.filter(message => message.subject === "approveRequestWithCurrentRevisions")
        .map(message => message.requestToken), [replacement.requestToken]);
    assert.equal(first.phase, "disposed");
    assert.equal(first.followUpTimer, null);
    assert.equal(second.followUpMode, "poll");
    assert.equal(harness.get("request-title").textContent, "Replacement B");
});

test("disposing a dispatched approval keeps its lane occupied until reply or timeout", async () => {
    for (const outcome of ["reply", "timeout"]) {
        const harness = await reviewedPopup();
        const first = harness.controller;
        const gate = deferred();
        harness.handlers.worker = (message, fallback) =>
            message.subject === "approveRequestWithCurrentRevisions" &&
                message.requestToken === first.request.requestToken
                ? gate.promise : fallback(message);
        const dispatched = first.submitCurrentDecision("approveRequest", {});
        await flushPopup();
        const firstTimeout = [...harness.timers.values()].find(timer => timer.delay === 190_000);
        const replacement = pendingRequest(first.request.id, 2);
        harness.setState(replacement, messageState(replacement, {title: "Replacement B"}));
        await harness.show([replacement]);
        const second = harness.controller;
        const queued = second.submitCurrentDecision("approveRequest", {});
        await flushPopup();
        const approvals = () => harness.workerMessages.filter(message =>
            message.subject === "approveRequestWithCurrentRevisions"
        );
        assert.equal(approvals().length, 1);
        assert.ok(harness.timers.has(firstTimeout.id));
        assert.equal(second.phase, "submitting");

        if (outcome === "reply") { gate.resolve({status: "ok"}); }
        else { await harness.fire(firstTimeout.id); }
        await dispatched;
        await queued;

        assert.deepEqual(approvals().map(message => message.requestToken), [
            first.request.requestToken, replacement.requestToken,
        ]);
        assert.equal(first.phase, "disposed");
        assert.equal(first.followUpTimer, null);
        assert.equal(second.followUpMode, "poll");
        const beforeLateReply = harness.visibleSnapshot();
        const followUp = second.followUpTimer;
        gate.resolve({status: "ok"});
        await flushPopup();
        assert.deepEqual(harness.visibleSnapshot(), beforeLateReply);
        assert.equal(second.followUpTimer, followUp);
    }
});

test("state transitions own one follow-up timer and ignore stale callbacks", async () => {
    const harness = await reviewedPopup(transactionState);
    const controller = harness.controller;
    const initial = controller.followUpTimer;
    const old = harness.timers.get(initial);
    controller.reconcileScheduling();
    controller.reconcileScheduling();
    assert.equal(controller.followUpTimer, initial);
    assert.equal(old.delay, 600);
    controller.adoptState({id: controller.request.id, state: "working", actions: []});
    const current = controller.followUpTimer;
    assert.equal(harness.timers.size, 1);
    assert.equal(harness.timers.get(current).delay, 400);

    old.callback();
    controller.reconcileScheduling();
    await flushPopup();

    assert.equal(controller.followUpTimer, current);
    assert.equal(harness.nativeMessages.length, 0);
    harness.setState(controller.request, {id: controller.request.id, state: "working", actions: []});
    await harness.fire(current);
    assert.equal(harness.timers.size, 1);
    assert.equal(controller.followUpMode, "poll");
    harness.setState(controller.request, transactionState(controller.request));
    await harness.fire(controller.followUpTimer);
    assert.equal(harness.timers.size, 1);
    assert.equal(controller.followUpMode, "refresh");
    assert.equal(harness.timers.get(controller.followUpTimer).delay, 600);
    const last = harness.timers.get(controller.followUpTimer);
    controller.dispose();
    last.callback();
    assert.equal(controller.followUpTimer, null);
    assert.equal(harness.timers.size, 0);
});

test("missing-state reconciliation shares one authoritative queue refresh", async () => {
    const harness = await reviewedPopup();
    const controller = harness.controller;
    const gate = deferred();
    const replacement = pendingRequest(controller.request.id, 2);
    harness.setState(replacement, messageState(replacement, {title: "Replacement B"}));
    harness.handlers.native = (message, fallback) =>
        message.subject === "getPendingRequests" ? gate.promise : fallback(message);

    const completion = controller.reconcileMissingRequest();
    const repeated = controller.reconcileMissingRequest();
    await flushPopup();

    assert.equal(completion, repeated);
    assert.equal(controller.phase, "reconciling");
    assert.equal(controller.isActive, false);
    assert.equal(harness.call("shouldDeferQueueRefreshForCurrentRequest"), false);
    assert.deepEqual(harness.nativeMessages.map(message => message.subject), ["getPendingRequests"]);
    gate.resolve({completedResponses: [], requests: [replacement]});
    await completion;
    await flushPopup();
    assert.equal(controller.phase, "disposed");
    assert.equal(harness.controller.request.requestToken, replacement.requestToken);
    assert.equal(harness.get("request-title").textContent, "Replacement B");
    assert.equal(harness.model.closed, 0);
});

test("reconciliation during the slider-await microtask prevents approval and rich mutation dispatch", async () => {
    for (const operation of ["approval", "mutation"]) {
        const harness = await reviewedPopup(transactionState);
        const controller = harness.controller;
        const queueGate = deferred();
        harness.handlers.native = (message, fallback) =>
            message.subject === "getPendingRequests" ? queueGate.promise : fallback(message);

        const pending = operation === "approval"
            ? controller.submitCurrentDecision("approveRequest", {})
            : controller.applyEdits();
        const completion = controller.reconcileMissingRequest();
        const before = harness.visibleSnapshot();
        await pending;
        await flushPopup();

        assert.equal(controller.phase, "reconciling");
        assert.equal(controller.isActive, false);
        assert.equal(controller.followUpTimer, null);
        assert.equal(controller.tickets.size, 0);
        assert.deepEqual(harness.nativeMessages.map(message => message.subject), ["getPendingRequests"]);
        assert.deepEqual(harness.workerMessages, []);
        assert.deepEqual(harness.visibleSnapshot(), before);
        queueGate.resolve({completedResponses: [], requests: []});
        await completion;
    }
});

test("queued and dispatched decisions cannot leave reconciliation after their late outcome", async () => {
    for (const stage of ["queued", "dispatched"]) {
        const harness = await reviewedPopup();
        const controller = harness.controller;
        const actionGate = deferred();
        const queueGate = deferred();
        harness.handlers.native = (message, fallback) => {
            if (message.subject === "getPendingRequests") { return queueGate.promise; }
            if (message.subject === "openApp") { return actionGate.promise; }
            return fallback(message);
        };
        harness.handlers.worker = (message, fallback) =>
            message.subject === "approveRequestWithCurrentRevisions" ? actionGate.promise : fallback(message);
        const predecessor = stage === "queued"
            ? harness.call("scheduleNativeMessage", "app", "openApp", 99)
            : null;
        if (predecessor) { await flushPopup(); }
        const decision = controller.submitCurrentDecision("approveRequest", {});
        await flushPopup();
        const completion = controller.reconcileMissingRequest();
        await flushPopup();
        const before = harness.visibleSnapshot();
        const focusCount = harness.focusCalls.length;

        actionGate.resolve({status: "ok"});
        if (predecessor) { await predecessor.result; }
        await decision;

        assert.equal(controller.phase, "reconciling");
        assert.equal(controller.isActive, false);
        assert.equal(controller.followUpTimer, null);
        assert.deepEqual(harness.visibleSnapshot(), before);
        assert.equal(harness.focusCalls.length, focusCount);
        assert.equal(harness.workerMessages.filter(message =>
            message.subject === "approveRequestWithCurrentRevisions"
        ).length, stage === "queued" ? 0 : 1);
        queueGate.resolve({completedResponses: [], requests: []});
        await completion;
        assert.equal(controller.phase, "disposed");
    }
});

test("update recovery renders pending approvals first and keeps a drained popup open", async () => {
    const request = pendingRequest();
    const harness = popupHarness({
        requests: [request],
        updateRecovery: true,
        tab: message => ({
            buildVersion: previousBuildVersion,
            nonce: message.nonce,
            subject: "workflowProbe",
            workflowVersion: 3,
        }),
    });
    harness.setState(request, messageState(request));
    await harness.boot();
    assert.equal(harness.get("request-title").textContent, "Sign message");
    assert.equal(harness.get("screen-request").classList.contains("hidden"), false);
    assert.ok(harness.queue.updateRecoveryTab);
    assert.equal(harness.tabMessages.length, 1);

    harness.model.requests = [];
    await harness.controller.reconcileMissingRequest();

    assert.equal(harness.model.closed, 0);
    assert.equal(harness.get("idle-connection").textContent, "Failed to load");
    assert.equal(harness.get("idle-check-status").classList.contains("hidden"), false);
    assert.equal(harness.get("idle-switch-account").disabled, true);
    assert.equal(harness.workerMessages.filter(message => message.subject === "getLatestConfiguration").length, 0);
});

test("keyboard slider input stays local and one terminal command adopts its rotated token", async () => {
    const harness = await reviewedPopup(transactionState);
    const controller = harness.controller;
    const gate = deferred();
    harness.handlers.native = (message, fallback) =>
        message.subject === "setTransactionSpeed" ? gate.promise : fallback(message);
    const slider = harness.get("tx-slider");
    slider.value = "120";
    slider.emit("input");
    slider.value = "145";
    slider.emit("input");
    await flushPopup();
    assert.equal(controller.transaction.sliderDragging, true);
    assert.deepEqual(harness.nativeMessages, []);
    slider.emit("change");
    const completion = controller.transaction.activeCommand.completion;
    await flushPopup();
    assert.equal(slider.disabled, true);
    assert.equal(controller.beginSliderInteraction(), false);
    assert.deepEqual(harness.nativeMessages, [{
        subject: "setTransactionSpeed",
        id: controller.request.id,
        workflowVersion: 3,
        requestToken: controller.request.requestToken,
        reviewToken: requestToken(101),
        payload: {interaction: "ended", value: 145},
        __bwPrivateBrowsing: false,
    }]);

    gate.resolve(transactionState(controller.request, {
        reviewToken: requestToken(102),
        slider: {maximum: 200, position: 145, visible: true},
    }));
    assert.equal(await completion, true);
    assert.equal(controller.transaction.activeCommand, null);
    assert.equal(controller.state.review.reviewToken, requestToken(102));
    assert.equal(controller.followUpMode, "refresh");
    assert.equal(Number(slider.value), 145);
});

test("approval waits for the drag result and ignores the old gesture's late terminal events", async () => {
    const harness = await reviewedPopup(transactionState);
    const controller = harness.controller;
    const gate = deferred();
    harness.handlers.native = (message, fallback) =>
        message.subject === "setTransactionSpeed" ? gate.promise : fallback(message);
    const slider = harness.get("tx-slider");
    slider.emit("pointerdown");
    slider.value = "160";
    slider.emit("input");
    const approval = harness.get("button-approve").emit("click");
    await flushPopup();
    assert.deepEqual(harness.nativeMessages.map(message => message.subject), ["setTransactionSpeed"]);
    assert.deepEqual(harness.workerMessages, []);

    gate.resolve(transactionState(controller.request, {reviewToken: requestToken(102)}));
    await approval;

    assert.equal(harness.workerMessages[0].subject, "approveRequestWithCurrentRevisions");
    assert.equal(harness.workerMessages[0].reviewToken, requestToken(102));
    assert.equal(controller.followUpMode, "poll");
    slider.emit("pointerup");
    slider.emit("change");
    await flushPopup();
    assert.equal(harness.nativeMessages.filter(message => message.subject === "setTransactionSpeed").length, 1);
    assert.equal(harness.workerMessages.length, 1);
});

test("stale or ignored terminal slider commands refresh and do not approve", async () => {
    for (const stale of [true, false]) {
        const harness = await reviewedPopup(transactionState);
        const controller = harness.controller;
        const fresh = transactionState(controller.request, {reviewToken: requestToken(102)});
        harness.setState(controller.request, fresh);
        harness.handlers.native = (message, fallback) =>
            message.subject === "setTransactionSpeed" ? {status: "ignored"} : fallback(message);
        const slider = harness.get("tx-slider");
        slider.emit("pointerdown");
        slider.value = "140";
        if (stale) { controller.adoptState(fresh); }

        await controller.submitCurrentDecision("approveRequest", {});

        assert.deepEqual(harness.nativeMessages.map(message => message.subject), stale
            ? ["getApprovalState"] : ["setTransactionSpeed", "getApprovalState"]);
        assert.deepEqual(harness.workerMessages, []);
        assert.equal(controller.state.review.reviewToken, requestToken(102));
        assert.equal(controller.transaction.activeCommand, null);
        assert.equal(controller.followUpMode, "refresh");
    }
});

test("queued slider commands are fenced by their captured review token", async () => {
    const harness = await reviewedPopup(transactionState);
    const controller = harness.controller;
    const gate = deferred();
    harness.handlers.native = (message, fallback) =>
        message.subject === "openApp" ? gate.promise : fallback(message);
    const predecessor = harness.call("scheduleNativeMessage", "app", "openApp", 99);
    await flushPopup();
    const slider = harness.get("tx-slider");
    slider.emit("pointerdown");
    slider.value = "140";
    slider.emit("change");
    const completion = controller.transaction.activeCommand.completion;
    await flushPopup();
    const fresh = transactionState(controller.request, {reviewToken: requestToken(102)});
    harness.setState(controller.request, fresh);
    controller.adoptState(fresh);

    gate.resolve({id: 99, opened: true});
    await predecessor.result;

    assert.equal(await completion, false);
    assert.deepEqual(harness.nativeMessages.map(message => message.subject), ["openApp", "getApprovalState"]);
    assert.equal(controller.state.review.reviewToken, requestToken(102));
});

test("replacement consumes the old drag's trailing events before accepting a new gesture", async () => {
    const harness = await reviewedPopup(transactionState);
    const first = harness.controller;
    const slider = harness.get("tx-slider");
    slider.emit("pointerdown");
    slider.value = "140";
    slider.emit("input");
    const replacement = pendingRequest(first.request.id, 2);
    const fresh = transactionState(replacement, {reviewToken: requestToken(202)});
    harness.setState(replacement, fresh);
    harness.handlers.native = (message, fallback) =>
        message.subject === "setTransactionSpeed" ? fresh : fallback(message);
    await harness.show([replacement]);
    harness.clearMessages();

    slider.emit("input");
    slider.emit("pointerup");
    slider.emit("change");
    await flushPopup();

    assert.equal(first.phase, "disposed");
    assert.equal(harness.controller.transaction.sliderDragging, false);
    assert.deepEqual(harness.nativeMessages, []);
    slider.emit("pointerdown");
    slider.value = "180";
    slider.emit("pointercancel");
    const completion = harness.controller.transaction.activeCommand.completion;
    assert.equal(await completion, true);
    assert.equal(harness.nativeMessages[0].requestToken, replacement.requestToken);
    assert.equal(harness.nativeMessages[0].reviewToken, requestToken(202));
    assert.deepEqual(harness.nativeMessages[0].payload, {interaction: "cancelled", value: 180});
});

test("transaction refresh leaves rendered fees and slider value alone during a terminal command", async () => {
    for (const changed of [false, true]) {
        const harness = await reviewedPopup(transactionState);
        const controller = harness.controller;
        const gate = deferred();
        const refreshed = transactionState(controller.request, changed ? {
            title: "Refreshed fees",
            slider: {maximum: 200, position: 175, visible: true},
        } : {});
        harness.setState(controller.request, refreshed);
        harness.handlers.native = (message, fallback) =>
            message.subject === "setTransactionSpeed" ? gate.promise : fallback(message);
        const completion = controller.startSliderCommand("ended", 145, controller.request);
        await flushPopup();
        harness.get("tx-slider").value = "145";
        const before = harness.visibleSnapshot();

        await controller.readState({refresh: true});

        assert.deepEqual(harness.visibleSnapshot(), before);
        assert.equal(controller.state.review.title, refreshed.review.title);
        gate.resolve(refreshed);
        assert.equal(await completion, true);
        assert.equal(harness.get("request-title").textContent, refreshed.review.title);
    }
});

test("editor inputs survive refresh and custom or suggested edits use exact native payloads", async () => {
    for (const usesEIP1559 of [false, true]) {
        const editor = usesEIP1559 ? {
            usesEIP1559: true,
            nonce: "1",
            maxPriorityFeePerGasGwei: "2",
            maxFeePerGasGwei: "20",
            suggestedMaxPriorityFeePerGasGwei: "3",
            suggestedMaxFeePerGasGwei: "30",
        } : {usesEIP1559: false, nonce: "1", gasPriceGwei: "2", suggestedGasPriceGwei: "3"};
        const harness = await reviewedPopup(request => transactionState(request, {editor}));
        const controller = harness.controller;
        harness.get("tx-editor").open = true;
        harness.get("edit-nonce").value = "9";
        harness.get("edit-nonce").emit("input");
        const custom = usesEIP1559
            ? {maxPriorityFeePerGasGwei: "5", maxFeePerGasGwei: "40"}
            : {gasPriceGwei: "5"};
        if (usesEIP1559) {
            harness.get("edit-max-priority").value = custom.maxPriorityFeePerGasGwei;
            harness.get("edit-max-fee").value = custom.maxFeePerGasGwei;
        } else {
            harness.get("edit-gas-price").value = custom.gasPriceGwei;
        }
        harness.setState(controller.request, transactionState(controller.request, {
            editor: {...editor, nonce: "2"}, reviewToken: requestToken(102),
        }));

        await controller.readState({refresh: true});

        assert.equal(harness.get("edit-nonce").value, "9");
        assert.equal(controller.transaction.editorDirty, true);
        assert.equal(harness.get(usesEIP1559 ? "edit-max-priority" : "edit-gas-price").value, "5");
        const committed = transactionState(controller.request, {
            editor: {...editor, ...custom, nonce: "9"}, reviewToken: requestToken(103),
        });
        harness.handlers.native = (message, fallback) =>
            message.subject === "applyTransactionEdits" ? committed : fallback(message);
        harness.clearMessages();

        await harness.get("editor-apply").emit("click");

        assert.deepEqual(harness.nativeMessages, [{
            subject: "applyTransactionEdits",
            id: controller.request.id,
            workflowVersion: 3,
            requestToken: controller.request.requestToken,
            reviewToken: requestToken(102),
            payload: {mode: "custom", nonce: "9", ...custom},
            __bwPrivateBrowsing: false,
        }]);
        assert.equal(harness.get("tx-editor").open, false);
        assert.equal(controller.transaction.editorDirty, false);
        assert.equal(controller.state.review.reviewToken, requestToken(103));
        harness.clearMessages();

        await harness.get("editor-suggested").emit("click");

        assert.equal(harness.nativeMessages[0].reviewToken, requestToken(103));
        assert.deepEqual(harness.nativeMessages[0].payload, {mode: "suggested"});
        assert.deepEqual(harness.workerMessages, []);
    }
});

test("an edit error preserves the open editor and typed values", async () => {
    const harness = await reviewedPopup(transactionState);
    const controller = harness.controller;
    harness.get("tx-editor").open = true;
    harness.get("edit-nonce").value = "invalid";
    harness.get("edit-nonce").emit("input");
    harness.handlers.native = (message, fallback) => message.subject === "applyTransactionEdits"
        ? transactionState(controller.request, {}, {editsError: true}) : fallback(message);

    await harness.get("editor-apply").emit("click");

    assert.equal(harness.get("tx-editor").open, true);
    assert.equal(harness.get("edit-nonce").value, "invalid");
    assert.equal(harness.get("edits-error").classList.contains("hidden"), false);
    assert.equal(controller.transaction.editorDirty, true);
    assert.equal(controller.followUpMode, "refresh");
});

test("alert clicks send the click-time review token and ignore a superseded response", async () => {
    const harness = await reviewedPopup(transactionState);
    const controller = harness.controller;
    const alert = {title: "Review fees", message: "", actions: [{title: "Cancel", action: "cancel"}]};
    harness.get("edit-nonce").focus();
    controller.adoptState(transactionState(controller.request, {alert}));
    const button = harness.get("alert-buttons").children[0];
    const gate = deferred();
    harness.handlers.native = (message, fallback) =>
        message.subject === "resolveApprovalAlert" ? gate.promise : fallback(message);

    const clicked = button.emit("click");
    await flushPopup();

    assert.deepEqual(harness.nativeMessages, [{
        subject: "resolveApprovalAlert",
        id: controller.request.id,
        workflowVersion: 3,
        requestToken: controller.request.requestToken,
        reviewToken: requestToken(101),
        payload: {action: "cancel"},
        __bwPrivateBrowsing: false,
    }]);
    controller.adoptState(transactionState(controller.request, {alert, reviewToken: requestToken(102)}));
    const before = harness.visibleSnapshot();
    const focusCount = harness.focusCalls.length;
    gate.resolve(transactionState(controller.request, {reviewToken: requestToken(999)}));
    await clicked;
    assert.equal(controller.state.review.reviewToken, requestToken(102));
    assert.deepEqual(harness.visibleSnapshot(), before);
    assert.equal(harness.focusCalls.length, focusCount);
});

test("disposed alert callbacks cannot close or focus the replacement request", async () => {
    const alert = {title: "Review fees", message: "", actions: [{title: "Cancel", action: "cancel"}]};
    const harness = await reviewedPopup(request => transactionState(request, {alert}));
    const first = harness.controller;
    const button = harness.get("alert-buttons").children[0];
    const gate = deferred();
    harness.handlers.native = (message, fallback) =>
        message.subject === "resolveApprovalAlert" ? gate.promise : fallback(message);
    const clicked = button.emit("click");
    await flushPopup();
    const replacement = pendingRequest(first.request.id, 2);
    harness.setState(replacement, transactionState(replacement, {
        alert: {...alert, title: "Replacement alert"},
        reviewToken: requestToken(202),
    }));
    await harness.show([replacement]);
    const before = harness.visibleSnapshot();
    const focusCount = harness.focusCalls.length;
    const timer = harness.controller.followUpTimer;

    gate.resolve(transactionState(first.request));
    await clicked;
    await button.emit("click");
    await flushPopup();

    assert.deepEqual(harness.visibleSnapshot(), before);
    assert.equal(harness.focusCalls.length, focusCount);
    assert.equal(harness.controller.followUpTimer, timer);
    assert.equal(harness.get("screen-request").inert, true);
    assert.equal(harness.get("alert-title").textContent, "Replacement alert");
    assert.equal(harness.nativeMessages.filter(message => message.subject === "resolveApprovalAlert").length, 1);
});

test("account selection belongs to one controller and old rows cannot change its replacement", async () => {
    const accounts = [
        {name: "Ethereum", croppedAddress: "0x1234", address: "0x" + "1".repeat(40),
            walletId: "wallet", coin: "ethereum", derivationPath: "m/44'/60'/0'/0/0", isSelected: false},
        {name: "Solana", croppedAddress: "So1234", address: "SolanaAddress",
            walletId: "wallet", coin: "solana", derivationPath: "m/44'/501'/0'/0'", isSelected: false},
    ];
    const selectionState = (request, selected = null) => ({
        id: request.id,
        host: request.host,
        state: "review",
        actions: ["approve", "reject"],
        review: {
            kind: "switchAccount",
            title: "Switch account",
            reviewToken: requestToken(101),
            accounts: accounts.map(account => ({...account, isSelected: account.coin === selected})),
            allowsEmptySelection: false,
            canSelectNetwork: true,
            networks: [{chainId: "0x1", name: "Ethereum", isSelected: true}],
        },
    });
    const harness = await reviewedPopup(selectionState);
    const first = harness.controller;
    const oldRow = harness.get("accounts-list").children[0];
    await oldRow.emit("click");
    assert.equal(first.presentation.accounts[0].coin, "ethereum");
    const replacement = pendingRequest(first.request.id, 2);
    harness.setState(replacement, selectionState(replacement, "solana"));
    await harness.show([replacement]);
    const focusCount = harness.focusCalls.length;

    await oldRow.emit("click");

    assert.deepEqual(normalized(harness.controller.presentation.accounts).map(account => account.coin), ["solana"]);
    assert.equal(harness.focusCalls.length, focusCount);
    harness.clearMessages();
    await harness.get("button-approve").emit("click");
    assert.equal(harness.workerMessages[0].requestToken, replacement.requestToken);
    assert.deepEqual(harness.workerMessages[0].payload, {
        chainId: "0x1",
        selectedAccounts: [{
            address: accounts[1].address,
            coin: "solana",
            derivationPath: accounts[1].derivationPath,
            walletId: "wallet",
        }],
    });
});

test("approval reads have one token-only shape for refresh and polling", async () => {
    const harness = await reviewedPopup(transactionState);
    const controller = harness.controller;
    await controller.readState({refresh: true});
    controller.adoptState({id: controller.request.id, state: "working", actions: []});
    await controller.readState();
    assert.deepEqual(harness.nativeMessages, Array.from({length: 2}, () => ({
        subject: "getApprovalState",
        id: controller.request.id,
        workflowVersion: 3,
        requestToken: controller.request.requestToken,
        __bwPrivateBrowsing: false,
    })));
});

test("an empty required account selection refreshes without retrying", async () => {
    const harness = await reviewedPopup(request => selectionState(request, {accounts: []}));
    const request = harness.controller.request;
    assert.equal(harness.get("button-approve").textContent, "Refresh");
    assert.equal(harness.get("button-approve").disabled, false);
    await harness.get("button-approve").emit("click");
    assert.deepEqual(harness.nativeMessages, [{
        subject: "getApprovalState", id: request.id, workflowVersion: 3,
        requestToken: request.requestToken, __bwPrivateBrowsing: false,
    }]);
    assert.deepEqual(harness.workerMessages, []);
});

test("busy polling removes capabilities while preserving the rendered review", async () => {
    for (const state of ["working", "authenticating"]) {
        const harness = await reviewedPopup(transactionState);
        const controller = harness.controller;
        const feeRows = harness.get("tx-fee-lines").children.slice();
        harness.get("tx-editor").open = true;
        harness.get("edit-nonce").value = "9";
        harness.get("edit-nonce").emit("input");
        harness.setState(controller.request, {id: controller.request.id, state, actions: []});
        await controller.readState();
        assert.equal(controller.state.review, undefined);
        assert.equal(harness.get("request-title").textContent, "Send transaction");
        assert.deepEqual(harness.get("tx-fee-lines").children, feeRows);
        assert.equal(harness.get("tx-editor").open, true);
        assert.equal(harness.get("edit-nonce").value, "9");
        assert.equal(controller.transaction.editorDirty, true);
        assert.equal(harness.get("button-approve").disabled, true);
        assert.equal(harness.get("button-reject").disabled, true);
        assert.equal(harness.get("tx-slider").disabled, true);
        assert.equal(harness.get("editor-apply").disabled, true);
        assert.equal(harness.get("working-overlay").classList.contains("hidden"), false);
        assert.equal(harness.get("screen-request").inert, true);
        assert.equal(controller.followUpMode, "poll");
        harness.clearMessages();
        await controller.approveCurrent();
        await controller.rejectCurrent();
        await controller.applySuggested();
        assert.deepEqual(harness.nativeMessages, []);
        assert.deepEqual(harness.workerMessages, []);
        harness.setState(controller.request, transactionState(controller.request, {
            editor: {...transactionState(controller.request).review.editor, nonce: "2"},
            reviewToken: requestToken(202),
        }));
        await controller.readState();
        assert.equal(harness.get("tx-editor").open, true);
        assert.equal(harness.get("edit-nonce").value, "9");
        assert.equal(controller.transaction.editorDirty, true);
        assert.equal(controller.state.review.reviewToken, requestToken(202));
        assert.equal(harness.get("button-approve").disabled, false);
        assert.equal(harness.get("screen-request").inert, false);
    }
});

test("busy refresh blocks keyboard interaction and restores error and alert behavior", async () => {
    const harness = await reviewedPopup(transactionState);
    const controller = harness.controller;
    const busy = {id: controller.request.id, state: "working", actions: []};
    harness.get("edit-nonce").focus();
    harness.setState(controller.request, busy);
    await controller.readState({refresh: true});
    assert.equal(harness.get("screen-request").inert, true);

    harness.setState(controller.request, {
        id: controller.request.id, state: "error", actions: ["retry"], error: "Failed",
    });
    await controller.readState();
    assert.equal(harness.get("screen-request").inert, false);
    assert.equal(harness.get("button-approve").disabled, false);

    controller.adoptState(busy);
    assert.equal(harness.get("screen-request").inert, true);
    const alert = {title: "Review fees", message: "", actions: [{title: "Cancel", action: "cancel"}]};
    controller.adoptState(transactionState(controller.request, {alert}));
    assert.equal(harness.get("screen-request").inert, true);
    assert.equal(harness.get("alert-overlay").classList.contains("hidden"), false);
    controller.adoptState(transactionState(controller.request));
    assert.equal(harness.get("screen-request").inert, false);
});

test("a busy replacement never displays another request's review", async () => {
    const harness = await reviewedPopup(transactionState);
    const replacement = pendingRequest(harness.controller.request.id, 2);
    harness.setState(replacement, {id: replacement.id, state: "working", actions: []});
    await harness.show([replacement]);
    assert.equal(harness.get("request-title").textContent, "");
    assert.equal(harness.get("section-transaction").classList.contains("hidden"), true);
    assert.equal(harness.get("button-approve").disabled, true);
});

test("transaction permissions disable mutations while retaining a dirty review editor", async () => {
    const harness = await reviewedPopup(transactionState);
    const controller = harness.controller;
    harness.get("tx-editor").open = true;
    harness.get("edit-nonce").value = "9";
    harness.get("edit-nonce").emit("input");
    harness.setState(controller.request, transactionState(controller.request, {
        phase: "preparing", editor: {...controller.state.review.editor, nonce: "2"},
    }, {actions: ["reject"]}));
    await controller.readState({refresh: true});
    assert.equal(harness.get("tx-editor").open, true);
    assert.equal(harness.get("edit-nonce").value, "9");
    assert.equal(controller.transaction.editorDirty, true);
    assert.equal(harness.get("button-approve").disabled, true);
    assert.equal(harness.get("button-reject").disabled, false);
    assert.equal(harness.get("tx-slider").disabled, true);
    assert.equal(harness.get("editor-apply").disabled, true);
    harness.clearMessages();
    await controller.applyEdits();
    await controller.applySuggested();
    assert.equal(await controller.mutateState("setTransactionSpeed", {interaction: "ended", value: 140}), null);
    assert.deepEqual(harness.nativeMessages, []);
});

test("retry fences an older read and adopts its returned review without another read", async () => {
    const harness = await reviewedPopup();
    const controller = harness.controller;
    const readGate = deferred();
    const retryGate = deferred();
    harness.handlers.native = (message, fallback) => {
        if (message.subject === "getApprovalState") { return readGate.promise; }
        if (message.subject === "retryApproval") { return retryGate.promise; }
        return fallback(message);
    };
    const oldRead = controller.readState();
    await flushPopup();
    controller.failClosedApprovalState(controller.request);
    const retry = controller.retryApproval();
    await flushPopup();
    readGate.resolve(messageState(controller.request, {title: "Old review"}));
    await oldRead;
    assert.equal(controller.state.state, "error");
    assert.equal(controller.phase, "submitting");
    assert.equal(harness.get("working-overlay").classList.contains("hidden"), false);
    retryGate.resolve(messageState(controller.request, {title: "Fresh review", reviewToken: requestToken(202)}));
    await retry;
    assert.equal(harness.get("request-title").textContent, "Fresh review");
    assert.equal(controller.state.review.reviewToken, requestToken(202));
    assert.deepEqual(harness.nativeMessages.map(message => message.subject), ["getApprovalState", "retryApproval"]);
    assert.equal(Object.hasOwn(harness.nativeMessages[1], "reviewToken"), false);
    assert.equal(Object.hasOwn(harness.nativeMessages[1], "payload"), false);
    assert.equal(controller.followUpTimer, null);
});

test("queued and dispatched retries cannot affect a replacement request", async () => {
    for (const queued of [false, true]) {
        const harness = await reviewedPopup();
        const first = harness.controller;
        first.failClosedApprovalState(first.request);
        const gate = deferred();
        harness.handlers.native = (message, fallback) =>
            message.subject === (queued ? "openApp" : "retryApproval") ? gate.promise : fallback(message);
        const predecessor = queued ? harness.call("scheduleNativeMessage", "app", "openApp", 99) : null;
        if (predecessor) { await flushPopup(); }
        const retry = first.retryApproval();
        await flushPopup();
        const replacement = pendingRequest(first.request.id, 2);
        harness.setState(replacement, messageState(replacement, {title: "Replacement", reviewToken: requestToken(202)}));
        await harness.show([replacement]);
        const before = harness.visibleSnapshot();
        gate.resolve(queued ? {id: 99, opened: true} : messageState(first.request, {title: "Stale retry"}));
        if (predecessor) { await predecessor.result; }
        await retry;
        assert.equal(harness.controller.request.requestToken, replacement.requestToken);
        assert.deepEqual(harness.visibleSnapshot(), before);
        assert.equal(harness.nativeMessages.filter(message => message.subject === "retryApproval").length, queued ? 0 : 1);
    }
});

test("retry follows busy states and reconciles missing requests", async () => {
    for (const state of ["working", "missing"]) {
        const harness = await reviewedPopup();
        const controller = harness.controller;
        controller.failClosedApprovalState(controller.request);
        harness.handlers.native = (message, fallback) => {
            if (message.subject === "retryApproval") {
                if (state === "missing") { harness.model.requests = []; }
                return {id: message.id, state, actions: []};
            }
            return fallback(message);
        };
        await controller.retryApproval();
        await flushPopup();
        if (state === "working") {
            assert.equal(controller.state.state, "working");
            assert.equal(controller.followUpMode, "poll");
            assert.equal(harness.get("working-overlay").classList.contains("hidden"), false);
        } else {
            assert.equal(controller.phase, "disposed");
            assert.equal(controller.followUpTimer, null);
            assert.equal(harness.model.closed, 1);
        }
    }
});

test("a nonreview refresh interrupts a slider gesture and disables stale controls", async () => {
    const harness = await reviewedPopup(transactionState);
    const controller = harness.controller;
    assert.equal(controller.beginSliderInteraction(controller.request), true);
    harness.setState(controller.request, {id: controller.request.id, state: "working", actions: []});
    await controller.readState({refresh: true});
    assert.equal(controller.transaction.sliderDragging, false);
    assert.equal(controller.state.review, undefined);
    assert.equal(harness.get("working-overlay").classList.contains("hidden"), false);
    assert.equal(harness.get("button-approve").disabled, true);
    assert.equal(harness.get("button-reject").disabled, true);
    assert.equal(harness.get("tx-slider").disabled, true);
});

test("late idle switch replies preserve preparing and working requests", async () => {
    for (const busy of [false, true]) {
        for (const succeeds of [false, true]) {
            const intent = deferred();
            const harness = popupHarness({tab: () => intent.promise});
            await harness.boot();
            const switching = harness.call("switchAccountFromIdle");
            await flushPopup();
            const request = pendingRequest();
            harness.model.requests = [request];
            harness.setState(request, busy
                ? {id: request.id, state: "working", actions: []}
                : transactionState(request, {phase: "preparing"}, {actions: ["reject"]}));
            harness.notify();
            await harness.fire(harness.queue.refreshTimer);
            const controller = harness.controller;
            const timer = controller.followUpTimer;
            const title = harness.get("request-title").textContent;
            const connection = harness.get("idle-connection").textContent;
            if (succeeds) {
                intent.resolve({
                    approvalRequired: true,
                    configurationKey: request.configurationKey,
                    id: 8,
                    requestToken: requestToken(2),
                    revisions: {ethereum: 0, solana: 0},
                    subject: "manualSwitchAcknowledged",
                    workflowVersion: 3,
                });
            } else {
                intent.reject(new Error("Late transport failure"));
            }
            await switching;
            await flushPopup();
            assert.equal(harness.controller, controller);
            assert.equal(controller.followUpTimer, timer);
            assert.equal(harness.get("request-title").textContent, title);
            assert.equal(harness.get("idle-connection").textContent, connection);
            assert.equal(harness.get("screen-loading").classList.contains("hidden"), true);
            assert.equal(harness.get("button-approve").disabled, true);

            harness.setState(request, transactionState(request));
            await harness.fire(timer);
            assert.equal(harness.get("button-approve").disabled, false);
            const next = pendingRequest(8, 2);
            harness.model.requests = succeeds ? [next] : [];
            harness.setState(next, selectionState(next));
            harness.setState(request, {id: request.id, state: "missing", actions: []});
            await harness.fire(controller.followUpTimer);
            assert.equal(controller.phase, "disposed");
            if (succeeds) {
                assert.equal(harness.controller.request.requestToken, next.requestToken);
            } else {
                assert.equal(harness.model.closed, 1);
            }
        }
    }
});

test("state reads coalesce and transaction polling preserves its backoff", async () => {
    const harness = await reviewedPopup(transactionState);
    const controller = harness.controller;
    const gate = deferred();
    harness.handlers.native = (message, fallback) =>
        message.subject === "getApprovalState" ? gate.promise : fallback(message);
    await harness.fire(controller.followUpTimer);
    const duplicate = controller.readState({refresh: true});
    controller.reconcileScheduling();
    controller.reconcileScheduling();
    await flushPopup();
    assert.equal(harness.nativeMessages.length, 1);
    assert.equal(controller.followUpTimer, null);
    gate.resolve(transactionState(controller.request));
    await duplicate;
    harness.handlers.native = undefined;
    for (const delay of [1200, 2400, 4800, 9600, 10000, 10000]) {
        const timer = controller.followUpTimer;
        assert.equal(harness.timers.get(timer).delay, delay);
        controller.reconcileScheduling();
        assert.equal(controller.followUpTimer, timer);
        await harness.fire(timer);
    }
    harness.setState(controller.request, transactionState(controller.request, {valueLine: "Changed value"}));
    await harness.fire(controller.followUpTimer);
    assert.equal(harness.timers.get(controller.followUpTimer).delay, 600);
    harness.setState(controller.request, transactionState(controller.request, {phase: "preparing"}, {actions: ["reject"]}));
    await harness.fire(controller.followUpTimer);
    assert.equal(harness.timers.get(controller.followUpTimer).delay, 600);
    harness.setState(controller.request, {id: controller.request.id, state: "authenticating", actions: []});
    await harness.fire(controller.followUpTimer);
    assert.equal(harness.timers.get(controller.followUpTimer).delay, 400);
    harness.setState(controller.request, transactionState(controller.request));
    await harness.fire(controller.followUpTimer);
    assert.equal(harness.timers.get(controller.followUpTimer).delay, 600);
});

test("late idle status lookups probes and reloads cannot replace an active request", async () => {
    for (const stage of ["query", "probe", "reload"]) {
        for (const changed of [false, true]) {
            const harness = popupHarness({
                updateRecovery: true,
                tab: message => ({
                    buildVersion: previousBuildVersion,
                    nonce: message.nonce,
                    subject: "workflowProbe",
                    workflowVersion: 3,
                }),
            });
            await harness.boot();
            assert.ok(harness.queue.updateRecoveryTab);
            const originalTab = harness.queue.activeTab;
            const recoveryTab = harness.queue.updateRecoveryTab;
            const gate = deferred();
            let reloads = 0;
            harness.browser.tabs.reload = () => {
                reloads += 1;
                return stage === "reload" ? gate.promise : Promise.resolve();
            };
            if (stage === "query") { harness.browser.tabs.query = () => gate.promise; }
            if (stage === "probe") { harness.handlers.tab = () => gate.promise; }
            const refreshing = harness.call("refreshIdleStatus");
            await flushPopup();
            const request = pendingRequest();
            harness.model.requests = [request];
            harness.setState(request, {id: request.id, state: "working", actions: []});
            harness.notify();
            await harness.fire(harness.queue.refreshTimer);
            const controller = harness.controller;
            const timer = controller.followUpTimer;
            if (stage === "query") {
                gate.resolve([{...harness.tab, id: 99, incognito: changed}]);
            } else if (stage === "probe") {
                gate.resolve({
                    buildVersion: changed ? packagedBuildVersion : previousBuildVersion,
                    nonce: harness.tabMessages.at(-1).message.nonce,
                    subject: "workflowProbe",
                    workflowVersion: 3,
                });
            } else if (changed) {
                gate.reject(new Error("Late reload failure"));
            } else {
                gate.resolve();
            }
            await refreshing;
            assert.equal(harness.model.closed, 0);
            assert.equal(reloads, stage === "reload" ? 1 : 0);
            assert.equal(harness.queue.activeTab, originalTab);
            assert.equal(harness.queue.updateRecoveryTab, recoveryTab);
            assert.equal(harness.controller, controller);
            assert.equal(controller.followUpTimer, timer);
            assert.equal(harness.get("screen-loading").classList.contains("hidden"), true);
            harness.setState(request, transactionState(request));
            await harness.fire(timer);
            assert.equal(harness.get("button-approve").disabled, false);
        }
    }
});

test("authoritative slider recovery upgrades a coalesced refresh before approval", async () => {
    for (const sameTurn of [false, true]) {
        const harness = await reviewedPopup(transactionState);
        const controller = harness.controller;
        const sliderGate = deferred();
        const readGate = deferred();
        harness.handlers.native = (message, fallback) => {
            if (message.subject === "setTransactionSpeed") { return sliderGate.promise; }
            if (message.subject === "getApprovalState") { return readGate.promise; }
            return fallback(message);
        };
        controller.beginSliderInteraction(controller.request);
        harness.get("tx-slider").value = "145";
        const command = controller.finishSliderInteraction("ended", controller.request);
        await flushPopup();
        controller.reconcileScheduling();
        await harness.fire(controller.followUpTimer);
        sliderGate.resolve({status: "ignored"});
        if (!sameTurn) { await flushPopup(); }
        const fresh = transactionState(controller.request, {
            reviewToken: requestToken(102),
            feeLines: ["Network fee: 99 ETH"],
            slider: {maximum: 200, position: 180, visible: true},
        });
        readGate.resolve(fresh);
        assert.equal(await command, false);
        assert.equal(controller.transaction.activeCommand, null);
        assert.deepEqual(harness.get("tx-fee-lines").children.map(row => row.textContent), fresh.review.feeLines);
        assert.equal(controller.state.review.reviewToken, fresh.review.reviewToken);
        if (!sameTurn) {
            assert.equal(harness.nativeMessages.filter(message => message.subject === "getApprovalState").length, 1);
        }
        assert.deepEqual(harness.workerMessages, []);
        await controller.approveCurrent();
        assert.equal(harness.workerMessages[0].reviewToken, fresh.review.reviewToken);
    }
});

test("a new empty idle presentation releases Refresh without disturbing its next action", async () => {
    for (const stage of ["query", "probe", "reload"]) {
        for (const fails of [false, true]) {
            const probe = message => ({
                buildVersion: previousBuildVersion,
                nonce: message.nonce,
                subject: "workflowProbe",
                workflowVersion: 3,
            });
            const harness = popupHarness({updateRecovery: true, tab: probe});
            await harness.boot();
            const oldGate = deferred();
            let reloads = 0;
            harness.browser.tabs.reload = () => {
                reloads += 1;
                return oldGate.promise;
            };
            if (stage === "query") { harness.browser.tabs.query = () => oldGate.promise; }
            if (stage === "probe") { harness.handlers.tab = () => oldGate.promise; }
            const oldRefresh = harness.call("refreshIdleStatus");
            await flushPopup();
            const oldProbe = harness.tabMessages.at(-1).message;
            assert.equal(harness.get("idle-check-status").disabled, true);
            harness.notify();
            await harness.fire(harness.queue.refreshTimer);
            assert.equal(harness.queue.snapshotStatus, "empty");
            assert.equal(harness.get("screen-idle").classList.contains("hidden"), false);
            assert.equal(harness.get("idle-check-status").disabled, false);

            const nextGate = deferred();
            harness.browser.tabs.query = () => nextGate.promise;
            harness.handlers.tab = probe;
            harness.browser.tabs.reload = async () => { reloads += 1; };
            const nextRefresh = harness.call("refreshIdleStatus");
            await flushPopup();
            assert.equal(harness.get("idle-check-status").disabled, true);
            if (fails) { oldGate.reject(new Error("Superseded refresh failed")); }
            else if (stage === "query") { oldGate.resolve([harness.tab]); }
            else if (stage === "probe") { oldGate.resolve(probe(oldProbe)); }
            else { oldGate.resolve(); }
            await oldRefresh;
            assert.equal(harness.get("idle-check-status").disabled, true);
            assert.equal(harness.model.closed, 0);
            nextGate.resolve([harness.tab]);
            await nextRefresh;
            assert.equal(reloads, stage === "reload" ? 2 : 1);
            assert.equal(harness.model.closed, 1);
        }
    }
});

test("a superseded recovery waiting for an old read cannot clear a newer error", async () => {
    const harness = await reviewedPopup(transactionState);
    const controller = harness.controller;
    const base = transactionState(controller.request);
    const oldGate = deferred();
    let reads = 0;
    harness.handlers.native = (message, fallback) => {
        if (message.subject === "getApprovalState") {
            reads += 1;
            return reads === 1 ? oldGate.promise : base;
        }
        if (message.subject === "setTransactionSpeed") { return {status: "ignored"}; }
        if (message.subject === "rejectRequest") { return Promise.reject(new Error("Reject transport failed")); }
        return fallback(message);
    };
    const oldRead = controller.readState({refresh: true});
    await flushPopup();
    controller.beginSliderInteraction(controller.request);
    harness.get("tx-slider").value = "145";
    const slider = controller.finishSliderInteraction("ended", controller.request);
    await flushPopup();
    await controller.rejectCurrent();
    assert.equal(controller.state.state, "error");
    oldGate.resolve(base);
    await oldRead;
    await slider;
    await flushPopup();
    assert.equal(controller.state.state, "error");
    assert.equal(harness.get("request-error").classList.contains("hidden"), false);
    assert.equal(controller.followUpTimer, null);
    assert.equal(reads, 1);
    assert.deepEqual(harness.nativeMessages.map(message => message.subject), [
        "getApprovalState", "setTransactionSpeed", "rejectRequest",
    ]);
    await controller.approveCurrent();
    assert.equal(harness.nativeMessages.at(-1).subject, "retryApproval");
    assert.equal(controller.state.state, "review");
    assert.deepEqual(harness.workerMessages, []);
});
