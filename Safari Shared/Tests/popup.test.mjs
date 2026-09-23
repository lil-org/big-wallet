// ∅ 2026 lil org

import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import vm from "node:vm";
import {deferred, normalized, nativeResult, nativeError} from "./test_helpers.mjs";
import {createPopupHarness, flushPopup, popupMarkup as markup} from "./popup_harness.mjs";

const wireSource = await readFile(new URL("../Resources/bridge_wire.js", import.meta.url), "utf8");
const wireContext = vm.createContext({URL});
new vm.Script(wireSource).runInContext(wireContext);
const packagedBuildVersion = wireContext.BigWalletBridgeWire.BUILD_VERSION;
assert.match(packagedBuildVersion, /^.+\+[0-9]+$/);
const previousBuildVersion = packagedBuildVersion.replace(
    /[0-9]+$/,
    value => String(Math.max(0, Number(value) - 1))
);

test("popup markup never renders a wallet password", () => {
    assert.doesNotMatch(markup, /type="password"|password-input|password-row/);
});

test("popup bounds extension messages and allows the full native approval relay", async () => {
    const harness = popupHarness();
    const extension = harness.call("settleExtensionMessage", deferred().promise);
    const extensionTimer = harness.timerHistory.at(-1);
    assert.equal(extensionTimer.delay, 5000);
    await harness.fire(extensionTimer.id);
    assert.deepEqual(normalized(await extension), {status: "timeout"});

    const approval = harness.call("settleNativeMessage", deferred().promise, true);
    const rejected = assert.rejects(approval, {name: "TimeoutError"});
    const approvalTimer = harness.timerHistory.at(-1);
    assert.equal(approvalTimer.delay, 190_000);
    await harness.fire(approvalTimer.id);
    await rejected;
});

test("configuration reads carry trusted tab identity", async () => {
    const harness = popupHarness();
    await harness.boot();
    assert.deepEqual(harness.workerMessages.filter(message =>
        message.subject === "getLatestConfiguration"
    ), [{
        subject: "getLatestConfiguration",
        host: "wallet.example",
        configurationKey: "https://wallet.example",
        workflowVersion: 3,
    }]);
});

test("native approve uses the worker proxy while other commands stay direct", async () => {
    const harness = popupHarness();
    const request = pendingRequest();
    await harness.call(
        "nativeMessage", "approveRequest", 7, {cluster: "devnet"},
        request.requestToken, requestToken(101), request
    );
    await harness.call("nativeMessage", "rejectRequest", 7, undefined, request.requestToken);
    await assert.rejects(harness.call(
        "nativeMessage", "approveRequest", 8,
        {password: "must-not-cross-native-boundary"},
        request.requestToken, requestToken(101), request
    ), /Password payloads are not supported/);

    assert.deepEqual(harness.workerMessages, [{
        subject: "approveRequestWithCurrentRevisions",
        id: 7,
        host: "wallet.example",
        configurationKey: "https://wallet.example",
        requestToken: request.requestToken,
        reviewToken: requestToken(101),
        payload: {cluster: "devnet"},
        privateBrowsing: false,
        workflowVersion: 3,
    }]);
    assert.deepEqual(harness.nativeMessages, [{
        subject: "rejectRequest",
        id: 7,
        requestToken: request.requestToken,
        workflowVersion: 3,
        __bwPrivateBrowsing: false,
    }]);
});

test("pending and completed queue entries require exact trusted identities", () => {
    const harness = popupHarness();
    const request = {...pendingRequest(), revisions: {ethereum: 1, solana: 2}};
    assert.equal(Boolean(harness.call("BigWalletPopupWire.decodeQueue", {requests: [request], completedResponses: []})), true);
    assert.equal(Boolean(harness.call("BigWalletPopupWire.decodeQueue", {requests: [{...request, configurationKey: undefined}], completedResponses: []})), false);
    assert.equal(Boolean(harness.call("BigWalletPopupWire.decodeQueue", {requests: [{...request, provider: "other"}], completedResponses: []})), false);
    assert.equal(Boolean(harness.call("BigWalletPopupWire.decodeQueue", {requests: [{...request, revisions: undefined}], completedResponses: []})), false);

    const completed = completedResponse(8);
    assert.equal(Boolean(harness.call("BigWalletPopupWire.decodeQueue", {requests: [], completedResponses: [completed]})), true);
    assert.equal(Boolean(harness.call("BigWalletPopupWire.decodeQueue", {requests: [], completedResponses: [{...completed, extra: true}]})), false);
    assert.equal(Boolean(harness.call("BigWalletPopupWire.decodeQueue", {requests: [], completedResponses: [{...completed, revisions: undefined}]})), false);
});

test("approval envelope validates capabilities and requires canonical review content", () => {
    const harness = popupHarness();
    const request = pendingRequest();
    const error = {id: request.id, state: "error", actions: ["retry"], error: "Failed"};
    const rejectable = {...error, actions: ["reject"]};
    const recoverable = {...error, actions: ["retry", "reject"]};
    for (const state of [
        messageState(request), transactionState(request), selectionState(request),
        error, rejectable, recoverable,
        {id: request.id, state: "working", actions: []},
        {id: request.id, state: "authenticating", actions: []},
        {id: request.id, state: "missing", actions: []},
    ]) {
        assert.equal(Boolean(harness.call("BigWalletPopupWire.decodeApprovalState", state, request.id)), true);
    }
    assert.equal(harness.call("shouldPollApprovalState", error), false);
    assert.equal(harness.call("canRejectApprovalState", error), false);
    assert.equal(harness.call("canRejectApprovalState", rejectable), true);
    assert.equal(harness.call("canRejectApprovalState", recoverable), true);
    assert.equal(harness.call("canSubmitDecision", "approveRequest", rejectable), false);
    for (const invalid of [
        {...error, actions: undefined}, {...error, actions: ["approve"]},
        {...error, actions: []}, {...error, actions: ["retry", "approve"]},
        {...error, actions: ["retry", "retry"]}, {...error, review: messageState(request).review},
        {...messageState(request), review: undefined},
        {...messageState(request), actions: ["reject", "reject"]},
        {...messageState(request), actions: ["editTransaction"]},
        {...messageState(request), actions: ["unknown"]},
        {...messageState(request), state: "working", actions: []},
        {id: request.id, state: "working", actions: ["reject"]},
    ]) {
        assert.equal(Boolean(harness.call("BigWalletPopupWire.decodeApprovalState", invalid, request.id)), false);
    }
});

const updateProbeTimeout = Symbol("timeout");
const updateProbeNonce = "00000001000000020000000300000004";

function updateRecoveryProbeHarness({
    incognito = false,
    permission = true,
    response,
} = {}) {
    const harness = popupHarness({tab: async message => {
        if (response instanceof Error) { throw response; }
        if (response === updateProbeTimeout) { return deferred().promise; }
        return typeof response === "function" ? response(message) : response;
    }});
    const permissionQueries = [];
    harness.browser.permissions.contains = async query => {
        permissionQueries.push(normalized(query));
        if (permission instanceof Error) { throw permission; }
        return permission;
    };
    const tab = {
        id: 7,
        configurationKey: "https://wallet.example",
        incognito,
        url: "https://wallet.example/dapp",
    };
    return {
        permissionQueries,
        tab,
        tabMessages: harness.tabMessages,
        async probe() {
            const result = harness.call("updateRecoveryTabFor", tab);
            await flushPopup();
            if (response === updateProbeTimeout) {
                const timer = harness.timerHistory.at(-1);
                assert.equal(timer.delay, 5000);
                await harness.fire(timer.id);
            }
            return result;
        },
    };
}

test("update recovery checks the exact content build response", async () => {
    const current = updateRecoveryProbeHarness({response: {
        buildVersion: packagedBuildVersion,
        nonce: updateProbeNonce,
        subject: "workflowProbe",
        workflowVersion: 3,
    }});
    assert.equal(await current.probe(), null);
    assert.deepEqual(current.tabMessages, [{
        id: 7,
        message: {
            nonce: updateProbeNonce,
            subject: "workflowProbe",
            workflowVersion: 3,
        },
    }]);
    assert.deepEqual(current.permissionQueries, [{origins: ["https://wallet.example/*"]}]);

    const oldBuild = updateRecoveryProbeHarness({response: {
        buildVersion: previousBuildVersion,
        nonce: updateProbeNonce,
        subject: "workflowProbe",
        workflowVersion: 3,
    }});
    assert.equal(await oldBuild.probe(), oldBuild.tab);
    for (const response of [undefined, updateProbeTimeout]) {
        const old = updateRecoveryProbeHarness({response});
        assert.equal(await old.probe(), old.tab);
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
        assert.equal(await forged.probe(), null);
    }
});

test("update recovery ignores private, denied, and receiverless tabs", async () => {
    const privateTab = updateRecoveryProbeHarness({incognito: true});
    assert.equal(await privateTab.probe(), null);
    assert.deepEqual(privateTab.tabMessages, []);
    for (const permission of [false, new Error("permission check failed")]) {
        const denied = updateRecoveryProbeHarness({permission});
        assert.equal(await denied.probe(), null);
        assert.deepEqual(denied.tabMessages, []);
    }
    const receiverless = updateRecoveryProbeHarness({response: new Error("no receiver")});
    assert.equal(await receiverless.probe(), null);
});

async function idleRecoveryRefreshHarness(reload = async () => {}) {
    const harness = popupHarness({updateRecovery: true, tab: message => ({
        buildVersion: previousBuildVersion,
        nonce: message.nonce,
        subject: "workflowProbe",
        workflowVersion: 3,
    })});
    await harness.boot();
    harness.clearMessages();
    let lookups = 0;
    const reloaded = [];
    harness.browser.tabs.query = async () => { lookups += 1; return [harness.tab]; };
    harness.browser.tabs.reload = id => { reloaded.push(id); return reload(); };
    return Object.assign(harness, {reloaded, lookups: () => lookups});
}

test("update recovery reloads only the active tab on explicit Refresh", async () => {
    const success = await idleRecoveryRefreshHarness();
    assert.deepEqual(success.reloaded, []);
    await success.get("idle-check-status").click();
    assert.deepEqual(success.reloaded, [success.tab.id]);
    assert.equal(success.tabMessages.length, 1);
    assert.equal(success.tabMessages[0].id, success.tab.id);
    assert.equal(success.lookups(), 1);
    assert.equal(success.model.closed, 1);

    const failure = await idleRecoveryRefreshHarness(async () => { throw new Error("reload failed"); });
    await failure.get("idle-check-status").click();
    assert.deepEqual(failure.reloaded, [failure.tab.id]);
    assert.equal(failure.lookups(), 1);
    assert.equal(failure.model.closed, 0);
    assert.equal(failure.get("idle-check-status").disabled, false);
    assert.equal(failure.get("idle-check-status").classList.contains("hidden"), false);
    assert.equal(failure.get("idle-connection").textContent, "Failed to load");

    const unknownQueue = await idleRecoveryRefreshHarness();
    unknownQueue.notify();
    await unknownQueue.get("idle-check-status").click();
    assert.deepEqual(unknownQueue.reloaded, []);
    assert.deepEqual(unknownQueue.tabMessages, []);
    assert.equal(unknownQueue.lookups(), 0);
    assert.equal(unknownQueue.nativeMessages.filter(message => message.subject === "getPendingRequests").length, 1);
});

test("update recovery requires the exact stored tab identity at click", async () => {
    for (const overrides of [
        {id: 8}, {incognito: true},
        {url: "https://other.example/dapp"},
        {url: "https://wallet.example/after-navigation"},
    ]) {
        const changed = await idleRecoveryRefreshHarness();
        Object.assign(changed.tab, overrides);
        await changed.get("idle-check-status").click();
        assert.deepEqual(changed.reloaded, []);
        assert.deepEqual(changed.tabMessages, []);
        assert.equal(changed.lookups(), 1);
        assert.equal(changed.nativeMessages.filter(message => message.subject === "getPendingRequests").length, 1);
        assert.equal(changed.queue.tab.activeTab.id, changed.tab.id);
        assert.equal(changed.queue.tab.activeTab.url, changed.tab.url);
        assert.equal(changed.queue.tab.recoveryTab, null);
    }
});

test("update recovery clears a candidate that now answers with this build", async () => {
    const recovered = await idleRecoveryRefreshHarness();
    recovered.handlers.tab = undefined;
    await recovered.get("idle-check-status").click();
    assert.deepEqual(recovered.reloaded, []);
    assert.equal(recovered.tabMessages.length, 1);
    assert.equal(recovered.nativeMessages.filter(message => message.subject === "getPendingRequests").length, 1);
    assert.equal(recovered.queue.tab.recoveryTab, null);
    assert.equal(recovered.get("idle-check-status").disabled, false);
});

test("queue notifications win the click probe without clearing recovery", async () => {
    const raced = await idleRecoveryRefreshHarness();
    const recoveryTab = raced.queue.tab.recoveryTab;
    const probe = deferred();
    raced.handlers.tab = () => probe.promise;
    const refresh = raced.queue.refreshIdleStatus();
    await flushPopup();
    raced.notify();
    probe.resolve({
        buildVersion: packagedBuildVersion,
        nonce: raced.tabMessages.at(-1).message.nonce,
        subject: "workflowProbe",
        workflowVersion: 3,
    });
    await refresh;
    assert.deepEqual(raced.reloaded, []);
    assert.equal(raced.lookups(), 1);
    assert.equal(raced.tabMessages.length, 1);
    assert.equal(raced.queue.tab.recoveryTab, recoveryTab);
    assert.equal(raced.nativeMessages.filter(message => message.subject === "getPendingRequests").length, 1);
});

function completedResponse(id) {
    return {
        id,
        host: "wallet.example",
        configurationKey: "https://wallet.example",
        requestToken: requestToken(id),
        revisions: {ethereum: 0, solana: 0},
    };
}

test("completed-response apply uses the exact worker contract", async () => {
    let workerResponse = {applied: true};
    const harness = popupHarness({worker: () => workerResponse});
    const request = {...completedResponse(7), revisions: {ethereum: 3, solana: 5}};
    assert.equal(await harness.call("applyCompletedResponse", request), "applied");
    workerResponse = {id: 7, missing: true};
    assert.equal(await harness.call("applyCompletedResponse", request), "missing");
    workerResponse = {id: 8, missing: true};
    assert.equal(await harness.call("applyCompletedResponse", request), "failure");
    assert.deepEqual(harness.workerMessages[0], {
        subject: "applyCompletedResponse",
        ...request,
        workflowVersion: 3,
    });
});

function recoveredQueueHarness({failedID, includeCompletions = true, missingID} = {}) {
    const firstApply = deferred();
    const applied = [];
    const pending = pendingRequest(3, 3);
    const harness = popupHarness({requests: [pending], worker: async (message, fallback) => {
        if (message.subject !== "applyCompletedResponse") { return fallback(message); }
        applied.push(message.id);
        if (message.id === 1) { await firstApply.promise; }
        if (message.id === failedID) { throw new Error("apply failed"); }
        const result = fallback(message);
        return message.id === missingID ? {id: message.id, missing: true} : result;
    }});
    vm.runInContext('popupQueue = new PopupQueueController(); popupQueue.presentation = {kind: "loading"};', harness.context);
    harness.model.completed = includeCompletions ? [completedResponse(1), completedResponse(2)] : [];
    return Object.assign(harness, {applied, pending, firstApply,
        notified: () => harness.workerMessages.filter(message => message.subject === "responseReady")
            .flatMap(message => message.ids),
    });
}

test("recovered completions apply in FIFO order before rendering queued work", async () => {
    const harness = recoveredQueueHarness();
    const refresh = harness.queue.refreshQueue();
    await flushPopup();
    assert.deepEqual(harness.applied, [1]);
    assert.equal(harness.controller, null);
    assert.equal(harness.get("screen-request").classList.contains("hidden"), true);
    harness.firstApply.resolve();
    await refresh;
    await flushPopup();
    assert.deepEqual(harness.applied, [1, 2]);
    assert.deepEqual(harness.notified(), [1, 2]);
    assert.equal(harness.controller.request.requestToken, harness.pending.requestToken);
});

test("a failed recovered completion keeps the queue in failed-load state", async () => {
    const harness = recoveredQueueHarness({failedID: 2});
    const refresh = harness.queue.refreshQueue();
    harness.firstApply.resolve();
    await refresh;
    await flushPopup();
    assert.deepEqual(harness.applied, [1, 2]);
    assert.deepEqual(harness.notified(), [1]);
    assert.equal(harness.controller, null);
    assert.equal(harness.queue.snapshot.kind, "failed");
    assert.equal(harness.get("idle-connection").textContent, "Failed to load");
    assert.deepEqual(harness.model.completed.map(item => item.id), [2]);
});

test("an absent missing response disappears through authoritative queue refresh", async () => {
    const harness = recoveredQueueHarness({includeCompletions: false});
    await harness.queue.refreshQueue();
    await flushPopup();
    assert.deepEqual(harness.applied, []);
    assert.deepEqual(harness.notified(), []);
    assert.equal(harness.controller.request.requestToken, harness.pending.requestToken);
});

test("an evicted recovered completion is skipped without hiding queued work", async () => {
    const harness = recoveredQueueHarness({missingID: 2});
    const refresh = harness.queue.refreshQueue();
    harness.firstApply.resolve();
    await refresh;
    await flushPopup();
    assert.deepEqual(harness.applied, [1, 2]);
    assert.deepEqual(harness.notified(), [1]);
    assert.equal(harness.controller.request.requestToken, harness.pending.requestToken);
});

test("a reopened popup drains every outstanding completion across batches", async () => {
    const completions = Array.from({length: 33}, (_, index) => completedResponse(index + 1));
    let outstanding = completions.slice();
    const pending = pendingRequest(99, 99);
    function openPopup(failedID) {
        const applied = [];
        const pageSizes = [];
        const harness = popupHarness({native: (message, fallback) => {
            if (message.subject !== "getPendingRequests") { return fallback(message); }
            const completedResponses = outstanding.slice(0, 16);
            pageSizes.push(completedResponses.length);
            return {completedResponses, requests: [pending]};
        }, worker: (message, fallback) => {
            if (message.subject !== "applyCompletedResponse") { return fallback(message); }
            if (message.id === failedID) { throw new Error("apply failed"); }
            applied.push(message.id);
            outstanding = outstanding.filter(item => item.id !== message.id);
            return {applied: true};
        }});
        return Object.assign(harness, {applied, pageSizes});
    }
    const first = openPopup(17);
    assert.equal(await first.call("fetchPendingResponse"), null);
    assert.deepEqual(first.applied, completions.slice(0, 16).map(item => item.id));
    assert.equal(outstanding[0].id, 17);

    const reopened = openPopup();
    const response = await reopened.call("fetchPendingResponse");
    assert.deepEqual(reopened.applied, completions.slice(16).map(item => item.id));
    assert.deepEqual(reopened.pageSizes, [16, 1, 0]);
    assert.deepEqual(normalized(response.requests), [pending]);
    assert.deepEqual(outstanding, []);
});

test("popup runtime policy rejects unauthorized notifications without queue or UI effects", async () => {
    for (const activeReview of [false, true]) {
        const harness = activeReview ? await reviewedPopup() : popupHarness();
        if (!activeReview) { await harness.boot(); }
        harness.clearMessages();
        const worker = {
            id: harness.browser.runtime.id,
            url: harness.browser.runtime.getURL(""),
        };
        const message = {subject: "pendingRequestAvailable", workflowVersion: 3};
        const senders = [
            null,
            {},
            {url: worker.url},
            {...worker, id: ""},
            {...worker, id: "foreign-extension"},
            {id: worker.id},
            {...worker, url: harness.browser.runtime.getURL("popup.html")},
            {...worker, url: `${worker.url}?spoof=1`},
            {...worker, url: `${worker.url}#spoof`},
            {...worker, url: harness.browser.runtime.getURL("unknown.html")},
            {...worker, tab: {id: 3}},
            {...worker, url: "https://wallet.example", tab: {id: 3}, frameId: 0},
            {...worker, url: "https://wallet.example", tab: {id: 3}, frameId: 1},
            {...worker, url: "data:text/html,hello"},
        ];
        const denied = senders.map(sender => ({sender, message}));
        denied.push(...[
            "rpc", "message-to-wallet", "getResponse", "getLatestConfiguration", "disconnect",
            "approveRequestWithCurrentRevisions", "applyCompletedResponse", "updatePendingRequestBadge",
            "responseReady", "workflowProbe", "manualSwitchIntent", "configurationChanged", "unknown",
        ].map(subject => ({sender: worker, message: {subject, workflowVersion: 3}})));
        denied.push(...[null, {...message, extra: true}, {...message, workflowVersion: 2}]
            .map(message => ({sender: worker, message})));
        const controller = harness.controller;
        const snapshot = () => ({
            revision: harness.queue.revision,
            snapshot: normalized(harness.queue.snapshot),
            fresh: harness.queue.isFresh,
            refresh: harness.queue.refresh,
            timers: [...harness.timers],
            timerCount: harness.timerHistory.length,
            visible: harness.visibleSnapshot(),
            closed: harness.model.closed,
        });
        const before = snapshot();
        harness.browser.storage.local.get = () => assert.fail("denied notification accessed storage");
        harness.browser.tabs.query = () => assert.fail("denied notification queried tabs");
        for (const {sender, message} of denied) {
            assert.deepEqual(harness.notify(message, sender), {returns: [false], responses: []});
        }
        await flushPopup();
        assert.equal(harness.controller, controller);
        assert.deepEqual(snapshot(), before);
        assert.deepEqual(harness.nativeMessages, []);
        assert.deepEqual(harness.workerMessages, []);
        assert.deepEqual(harness.tabMessages, []);
    }
});

test("a pending-request notification refreshes an already-open idle popup", async () => {
    const harness = popupHarness();
    await harness.boot();
    const request = pendingRequest(60, 60);
    harness.model.requests = [request];
    harness.notify();
    assert.equal(harness.timers.get(harness.queue.refresh.timer).delay, 0);
    await harness.fire(harness.queue.refresh.timer);
    assert.equal(harness.controller.request.requestToken, request.requestToken);
    assert.deepEqual(normalized(harness.queue.snapshot.requests), [request]);
});

test("a pending-request notification fences a stale initial empty queue", async () => {
    const initial = deferred();
    const request = pendingRequest(61, 61);
    let reads = 0;
    const harness = popupHarness({native: (message, fallback) =>
        message.subject === "getPendingRequests" && ++reads === 1
            ? initial.promise : fallback(message),
    });
    await harness.boot();
    harness.model.requests = [request];
    harness.notify();
    initial.resolve({completedResponses: [], requests: []});
    await flushPopup();
    assert.equal(harness.nativeMessages.filter(message => message.subject === "getPendingRequests").length, 2);
    assert.equal(harness.controller.request.requestToken, request.requestToken);
    assert.equal(harness.workerMessages.some(message => message.subject === "getLatestConfiguration"), false);
});

test("notification bursts coalesce into one scheduled refresh and one necessary follow-up", async () => {
    const harness = popupHarness();
    await harness.boot();
    harness.clearMessages();
    harness.timerHistory.length = 0;
    const firstRead = deferred();
    const request = pendingRequest(62, 62);
    let reads = 0;
    harness.handlers.native = (message, fallback) =>
        message.subject === "getPendingRequests" && ++reads === 1
            ? firstRead.promise : fallback(message);

    for (let index = 0; index < 3; index += 1) { harness.notify(); }
    assert.equal(harness.timerHistory.filter(timer => timer.delay === 0).length, 1);
    assert.equal(harness.nativeMessages.length, 0);
    await harness.fire(harness.queue.refresh.timer);
    assert.equal(reads, 1);
    const flight = harness.queue.refresh.promise;
    assert.equal(harness.queue.refreshQueue(), flight);
    for (let index = 0; index < 3; index += 1) { harness.notify(); }
    harness.model.requests = [request];
    firstRead.resolve({completedResponses: [], requests: []});
    await flight;
    await flushPopup();

    assert.equal(reads, 2);
    assert.equal(harness.timerHistory.filter(timer => timer.delay === 0).length, 1);
    assert.equal(harness.controller.request.requestToken, request.requestToken);
    assert.equal(harness.queue.refresh.kind, "idle");
    assert.equal(harness.queue.isFresh, true);
    assert.equal(harness.workerMessages.some(message => message.subject === "getLatestConfiguration"), false);
});

test("queue invalidation preserves the active review and its selections until reconciliation", async () => {
    const harness = await reviewedPopup(selectionState);
    const controller = harness.controller;
    await harness.get("accounts-list").children[0].click();
    const selected = normalized(controller.presentation.accounts);
    const accountRow = harness.get("accounts-list").children[0];
    const review = controller.state;
    const next = pendingRequest(63, 63);
    harness.model.requests = [controller.request, next];

    harness.notify();
    harness.notify();
    await harness.queue.refreshQueue();
    await flushPopup();
    assert.equal(harness.queue.isFresh, false);
    assert.equal(harness.queue.refresh.kind, "idle");
    assert.equal(harness.controller, controller);
    assert.equal(controller.state, review);
    assert.deepEqual(normalized(controller.presentation.accounts), selected);
    assert.equal(harness.get("accounts-list").children[0], accountRow);
    assert.equal(harness.nativeMessages.length, 0);

    harness.model.requests = [next];
    harness.setState(controller.request, {id: controller.request.id, state: "missing", actions: []});
    harness.setState(next, selectionState(next));
    await controller.readState();
    await flushPopup();
    assert.equal(controller.activity.kind, "disposed");
    assert.equal(harness.controller.request.requestToken, next.requestToken);
    assert.equal(harness.nativeMessages.filter(message => message.subject === "getPendingRequests").length, 1);
});

test("a failed refresh retains the badge without scheduling automatic retries", async () => {
    const harness = await reviewedPopup();
    harness.handlers.native = (message, fallback) => {
        if (message.subject === "getPendingRequests") { throw new Error("Unavailable"); }
        return fallback(message);
    };
    await harness.controller.reconcile();
    await flushPopup();
    const failed = harness.queue.snapshot;
    assert.equal(failed.kind, "failed");
    assert.equal(harness.queue.isFresh, true);
    assert.equal(harness.queue.refresh.kind, "idle");
    assert.equal(harness.model.closed, 0);
    assert.equal(harness.workerMessages.some(message => message.subject === "updatePendingRequestBadge"), false);
    assert.equal(harness.get("idle-check-status").classList.contains("hidden"), false);
    assert.equal(harness.timers.size, 0);

    harness.notify();
    assert.equal(harness.queue.snapshot, failed);
    assert.equal(harness.queue.isFresh, false);
    assert.equal(harness.get("idle-check-status").classList.contains("hidden"), false);
    await harness.fire(harness.queue.refresh.timer);
    assert.equal(harness.queue.snapshot.kind, "failed");
    assert.equal(harness.queue.refresh.kind, "idle");
    assert.equal(harness.timers.size, 0);
    assert.equal(harness.nativeMessages.filter(message => message.subject === "getPendingRequests").length, 2);
    await harness.queue.refreshIdleStatus();
    assert.equal(harness.nativeMessages.filter(message => message.subject === "getPendingRequests").length, 3);
    assert.equal(harness.workerMessages.some(message => message.subject === "updatePendingRequestBadge"), false);
});

test("DOM visibility changes cannot enable idle switching or replace an active review", async () => {
    const harness = await reviewedPopup();
    const controller = harness.controller;
    harness.get("screen-request").classList.add("hidden");
    harness.get("screen-idle").classList.remove("hidden");
    harness.get("idle-switch-account").disabled = false;
    await harness.queue.switchAccountFromIdle();
    await harness.queue.refreshIdleStatus();
    harness.notify();
    await harness.queue.refreshQueue();
    assert.equal(controller.isActive, true);
    assert.equal(harness.controller, controller);
    assert.equal(harness.queue.refresh.kind, "idle");
    assert.deepEqual(harness.nativeMessages, []);
    assert.deepEqual(harness.tabMessages, []);
});

test("an invalidation before the empty-result close check prevents closure", async () => {
    const harness = await reviewedPopup();
    const controller = harness.controller;
    harness.model.requests = [];
    let invalidated = false;
    harness.handlers.worker = (message, fallback) => {
        if (message.subject === "getLatestConfiguration" && !invalidated) {
            assert.equal(harness.queue.isEmpty, true);
            invalidated = true;
            harness.notify();
        }
        return fallback(message);
    };
    await controller.reconcile();
    await flushPopup();
    assert.equal(invalidated, true);
    assert.equal(harness.model.closed, 0);
    assert.equal(harness.queue.isFresh, false);
    assert.equal(harness.get("idle-switch-account").disabled, true);
    const next = pendingRequest(64, 64);
    harness.model.requests = [next];
    await harness.fire(harness.queue.refresh.timer);
    assert.equal(harness.controller.request.requestToken, next.requestToken);
    assert.equal(harness.model.closed, 0);
});

test("idle operation ownership prevents repeat actions even if controls are enabled", async () => {
    const admission = deferred();
    const harness = await manualSwitchHarness(() => admission.promise);
    const switching = harness.queue.switchAccountFromIdle();
    await flushPopup();
    harness.get("idle-switch-account").disabled = false;
    harness.get("idle-check-status").disabled = false;
    await harness.queue.switchAccountFromIdle();
    await harness.queue.refreshIdleStatus();
    assert.equal(harness.tabMessages.length, 1);
    assert.deepEqual(harness.nativeMessages, []);
    admission.resolve(manualSwitchAcknowledgement());
    await switching;

    const recovery = await idleRecoveryRefreshHarness();
    const lookup = deferred();
    let lookups = 0;
    recovery.browser.tabs.query = () => { lookups += 1; return lookup.promise; };
    const refreshing = recovery.queue.refreshIdleStatus();
    await flushPopup();
    recovery.get("idle-check-status").disabled = false;
    await recovery.queue.refreshIdleStatus();
    assert.equal(lookups, 1);
    lookup.resolve([recovery.tab]);
    await refreshing;
    assert.equal(recovery.model.closed, 1);
});

async function manualSwitchHarness(sendMessage) {
    const harness = popupHarness({tab: message => sendMessage(harness.tabMessages.length, message)});
    await harness.boot();
    harness.clearMessages();
    harness.timerHistory.length = 0;
    return harness;
}

function manualSwitchAcknowledgement(overrides = {}) {
    return {
        approvalRequired: true,
        configurationKey: "https://wallet.example",
        id: 41,
        requestToken: requestToken(41),
        revisions: {ethereum: 0, solana: 0},
        subject: "manualSwitchAcknowledged",
        workflowVersion: 3,
        ...overrides,
    };
}

test("manual Switch Account sends one exact stateless intent with a full native admission window", async () => {
    const harness = await manualSwitchHarness(async () => manualSwitchAcknowledgement());
    const queue = deferred();
    harness.handlers.native = () => queue.promise;
    const switching = harness.queue.switchAccountFromIdle();
    await flushPopup();
    assert.deepEqual(harness.tabMessages, [{
        id: harness.tab.id,
        message: {
            configurationKey: "https://wallet.example",
            subject: "manualSwitchIntent",
            workflowVersion: 3,
        },
    }]);
    assert.equal(harness.nativeMessages.length, 1);
    assert.equal(harness.nativeMessages[0].subject, "getPendingRequests");
    assert.equal(harness.get("idle-switch-account").disabled, true);
    assert.equal(harness.timerHistory[0].delay, 10_000);
    queue.resolve({completedResponses: [], requests: []});
    await switching;
});

test("manual Switch Account accepts canonical native handles and terminal success", async () => {
    const responses = [
        manualSwitchAcknowledgement({approvalRequired: false, id: 17, revisions: {ethereum: 3, solana: 2}}),
        manualSwitchAcknowledgement(),
        nativeResult({
            id: 41,
            name: "switchAccount",
            provider: "multiple",
            result: null,
            mutation: {kind: "accounts", updates: {}},
        }),
    ];
    for (const response of responses) {
        const harness = await manualSwitchHarness(async () => response);
        await harness.get("idle-switch-account").click();
        assert.equal(harness.nativeMessages.length, 1);
        assert.equal(harness.nativeMessages[0].subject, "getPendingRequests");
        assert.equal(harness.queue.isEmpty, true);
        assert.notEqual(harness.get("idle-connection").textContent, "Failed to load");
    }
});

test("manual Switch Account shows terminal errors and permits retry", async () => {
    for (const error of [
        {code: -32603, message: "Too many account switches are pending. Finish one, then try again."},
        {code: 4001, message: "Canceled"},
    ]) {
        const harness = await manualSwitchHarness(async attempt => attempt === 1
            ? nativeError({id: 41, name: "switchAccount", provider: "multiple", error})
            : manualSwitchAcknowledgement());
        await harness.get("idle-switch-account").click();
        assert.equal(harness.get("idle-connection").textContent, error.message);
        assert.equal(harness.get("idle-switch-account").disabled, false);
        assert.equal(harness.get("idle-switch-account").classList.contains("hidden"), false);
        assert.deepEqual(harness.nativeMessages, []);

        await harness.get("idle-switch-account").click();
        assert.equal(harness.tabMessages.length, 2);
        assert.equal(harness.nativeMessages[0].subject, "getPendingRequests");
    }
});

test("an earlier idle configuration read cannot overwrite a manual Switch Account error", async () => {
    const configuration = deferred();
    const error = {code: -32603, message: "Too many account switches are pending. Finish one, then try again."};
    const harness = popupHarness({
        worker: (message, fallback) => message.subject === "getLatestConfiguration"
            ? configuration.promise : fallback(message),
        tab: () => nativeError({id: 41, name: "switchAccount", provider: "multiple", error}),
    });
    await harness.boot();
    await harness.get("idle-switch-account").click();
    configuration.resolve({kind: "configuration", state: {
        ethereum: {address: "", chainId: "0x1"}, solana: null,
        revisions: {ethereum: 0, solana: 0},
    }});
    await flushPopup();
    assert.equal(harness.get("idle-connection").textContent, error.message);
    assert.equal(harness.get("idle-switch-account").disabled, false);
});

test("manual Switch Account rejects undefined malformed and cross-key replies", async () => {
    for (const response of [
        undefined,
        {id: 41, name: "switchAccount"},
        {admissionDeadline: Date.now() + 60_000, configurationKey: "https://wallet.example",
            id: 41, subject: "manualSwitchInFlight", workflowVersion: 3},
        manualSwitchAcknowledgement({configurationKey: "https://other.example"}),
        manualSwitchAcknowledgement({id: "41"}),
    ]) {
        const harness = await manualSwitchHarness(async () => response);
        await harness.get("idle-switch-account").click();
        assert.equal(harness.get("idle-switch-account").disabled, false);
        assert.deepEqual(harness.nativeMessages, []);
        assert.equal(harness.get("idle-connection").textContent, "Failed to load");
    }
});

test("manual Switch Account repeats the same intent after transport failure", async () => {
    const harness = await manualSwitchHarness(async attempt => {
        if (attempt === 1) { throw new Error("unavailable"); }
        return manualSwitchAcknowledgement();
    });
    await harness.get("idle-switch-account").click();
    assert.equal(harness.get("idle-switch-account").disabled, false);
    await harness.get("idle-switch-account").click();
    assert.equal(harness.tabMessages.length, 2);
    assert.deepEqual(harness.tabMessages[0].message, harness.tabMessages[1].message);
    assert.equal(harness.nativeMessages.length, 1);
    assert.equal(harness.nativeMessages[0].subject, "getPendingRequests");
});

for (const recovery of ["queue failure", "extension update"]) {
    test(`queue refresh preserves Refresh after ${recovery}`, async () => {
        let queueFails = recovery === "queue failure";
        const harness = popupHarness({
            updateRecovery: recovery === "extension update",
            native: (message, fallback) => {
                if (queueFails) { throw new Error("Native unavailable"); }
                return fallback(message);
            },
            tab: message => ({
                buildVersion: previousBuildVersion,
                nonce: message.nonce,
                subject: "workflowProbe",
                workflowVersion: 3,
            }),
        });
        await harness.boot();
        const refresh = harness.get("idle-check-status");
        assert.equal(harness.get("idle-connection").textContent, "Failed to load");
        assert.equal(refresh.classList.contains("hidden"), false);
        assert.equal(refresh.disabled, false);
        assert.equal(harness.get("idle-switch-account").disabled, true);

        queueFails = false;
        harness.handlers.tab = undefined;
        await refresh.click();
        assert.equal(refresh.classList.contains("hidden"), true);
        assert.equal(harness.get("idle-switch-account").disabled, false);
    });
}

function requestToken(value) {
    return `00000000-0000-0000-0000-${String(value).padStart(12, "0")}`;
}

function commandReply(approval, status = "ok") {
    return {status, approval};
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

function popupHarness(options = {}) {
    const states = new Map;
    const handlers = {native: options.native, worker: options.worker, tab: options.tab};
    const model = {
        completed: [],
        requests: options.requests || [],
        updateRecovery: options.updateRecovery === true,
    };
    const tab = {id: 3, incognito: false, url: "https://wallet.example/path"};
    const defaultNative = message => {
        if (message.subject === "getPendingRequests") {
            return {completedResponses: model.completed, requests: model.requests};
        }
        return commandReply(states.get(message.requestToken) || messageState({
            id: message.id, host: "wallet.example",
        }));
    };
    const defaultWorker = message => {
        if (message.subject === "getLatestConfiguration") {
            return {kind: "configuration", state: {ethereum: {address: "", chainId: "0x1"}, solana: null, revisions: {ethereum: 0, solana: 0}}};
        }
        if (message.subject === "applyCompletedResponse") {
            model.completed = model.completed.filter(item => item.requestToken !== message.requestToken);
            return {applied: true};
        }
        if (message.subject === "approveRequestWithCurrentRevisions") { return defaultNative(message); }
        return {status: "ok"};
    };
    const harness = createPopupHarness({
        model,
        tab,
        native: message => handlers.native ? handlers.native(message, defaultNative) : defaultNative(message),
        worker: message => handlers.worker ? handlers.worker(message, defaultWorker) : defaultWorker(message),
        storageGet: async () => ({workflowUpdateRecoveryNeeded: model.updateRecovery}),
        tabMessage: message => handlers.tab ? handlers.tab(message) : {
            buildVersion: packagedBuildVersion,
            nonce: message.nonce,
            subject: "workflowProbe",
            workflowVersion: 3,
        },
    });
    const {context, nativeMessages, timers} = harness;
    Object.defineProperties(harness, {
        controller: {get: () => vm.runInContext("popupQueue?.currentRequest ?? null", context)},
        queue: {get: () => vm.runInContext("popupQueue", context)},
    });
    return Object.assign(harness, {
        handlers, states, tab,
        call(name, ...arguments_) { return vm.runInContext(name, context)(...arguments_); },
        setState(request, state) { states.set(request.requestToken, state); },
        async failTransport(controller = this.controller) {
            const handler = handlers.native;
            handlers.native = (message, fallback) => {
                if (message.subject === "rejectRequest") {
                    return Promise.reject(new Error("Native transport failed"));
                }
                return handler ? handler(message, fallback) : fallback(message);
            };
            await controller.reject();
            handlers.native = handler;
            nativeMessages.splice(nativeMessages.findIndex(message => message.subject === "rejectRequest"), 1);
        },
        async show(requests) {
            model.requests = requests;
            this.queue.snapshot = {kind: "ready", revision: this.queue.revision, requests};
            this.queue.presentSnapshot();
            await flushPopup();
            return this.controller;
        },
        followUpTimerId(excludedIds = []) {
            const delays = [400, 600, 1200, 2400, 4800, 9600, 10000];
            const matches = [...timers.values()].filter(timer =>
                delays.includes(timer.delay) && !excludedIds.includes(timer.id)
            );
            assert.ok(matches.length <= 1, "Expected at most one follow-up timer");
            return matches[0]?.id ?? null;
        },
    });
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

test("additional approval display fields leave rendering and approval payloads unchanged", async () => {
    for (const stateFor of [messageState, transactionState, selectionState]) {
        const request = pendingRequest();
        const state = stateFor(request);
        const baseline = popupHarness({requests: [request]});
        const extended = popupHarness({requests: [request]});
        baseline.setState(request, state);
        extended.setState(request, {
            ...state,
            displayMetadata: {label: "Future display metadata"},
            canApprove: false,
            canReject: false,
            payload: {password: "ignored", selectedAccounts: []},
            revisions: {ethereum: 999, solana: 999},
        });

        await baseline.boot();
        await extended.boot();

        assert.equal((extended.controller.presentationActivity.kind === "failed"), false);
        assert.deepEqual(extended.visibleSnapshot(), baseline.visibleSnapshot());

        await baseline.get("button-approve").click();
        await extended.get("button-approve").click();

        const approvals = harness => harness.workerMessages.filter(message =>
            message.subject === "approveRequestWithCurrentRevisions"
        );
        assert.equal(approvals(baseline).length, 1);
        assert.deepEqual(approvals(extended), approvals(baseline));
    }
});

test("additional display fields cannot grant actions or repair invalid approval content", async () => {
    const request = pendingRequest();
    const extras = {canApprove: true, canReject: true, reviewToken: requestToken(102)};
    const error = {id: request.id, state: "error", actions: ["reject"], error: "Failed"};
    const harness = popupHarness({requests: [request]});
    harness.setState(request, {...error, ...extras});

    await harness.boot();
    harness.clearMessages();
    await harness.get("button-approve").click();

    assert.equal((harness.controller.presentationActivity.kind === "failed"), false);
    assert.equal(harness.get("button-approve").disabled, true);
    assert.equal(harness.get("button-reject").disabled, false);
    assert.deepEqual(harness.workerMessages, []);
    for (const state of [
        messageState(request, {}, {id: request.id + 1}),
        messageState(request, {reviewToken: "invalid"}),
        messageState(request, {meta: undefined}),
        messageState(request, {}, {actions: ["unknown"]}),
    ]) {
        assert.equal(Boolean(harness.call("BigWalletPopupWire.decodeApprovalState", {...state, ...extras}, request.id)), false);
    }
});

test("approval reviews omit malformed images without changing approval content or source responses", async () => {
    const request = pendingRequest();
    for (const original of [messageState(request), transactionState(request), selectionState(request)]) {
        for (const image of [null, false, 7, {}, []]) {
            const response = {
                ...original,
                review: Object.freeze({
                    ...original.review,
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
            assert.equal(harness.get("requester-icon").src, "images/requester-globe.svg");
            assert.equal(harness.get("button-approve").disabled, false);
            assert.deepEqual(normalized(response), before);
        }
    }
});

test("approval reviews use a bundled requester icon and preserve account images", async () => {
    for (const images of [{}, {icon: "data:image/png;base64,aW1hZ2U="}]) {
        const request = pendingRequest();
        const response = messageState(request, {
            account: {name: "Primary", croppedAddress: "0x1234", ...(images.icon ? {icon: images.icon} : {})},
        });
        const harness = popupHarness({requests: [request]});
        harness.setState(request, response);

        await harness.boot();

        assert.deepEqual(normalized(harness.controller.state), response);
        assert.equal(harness.get("requester-icon").classList.contains("hidden"), false);
        assert.equal(harness.get("requester-icon").src, "images/requester-globe.svg");
        const accountImages = harness.get("signing-account").children.filter(child => child.className === "account-icon");
        assert.equal(accountImages.length, images.icon ? 1 : 0);
        if (images.icon) { assert.equal(accountImages[0].src, images.icon); }
    }
});

test("poll and transaction edit responses use the same nonfatal image normalization", async () => {
    const harness = await reviewedPopup(transactionState);
    const controller = harness.controller;
    const response = transactionState(controller.request, {
        account: {name: "Primary", croppedAddress: "0x1234", icon: false},
        reviewToken: requestToken(102),
        valueLine: "Value: 1 ETH",
    });
    const before = normalized(response);
    harness.setState(controller.request, response);
    controller.adoptState({id: controller.request.id, state: "working", actions: []});
    controller.scheduleRead();

    await harness.fire(harness.followUpTimerId());

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
        message.subject === "applyTransactionEdits" ? commandReply(edited) : fallback(message);

    harness.get("tx-editor").open = true;
    harness.get("tx-editor").emit("toggle");
    await harness.get("editor-suggested").click();

    assert.equal(controller.state.state, "review");
    assert.equal(controller.state.review.reviewToken, requestToken(103));
    assert.equal(harness.get("edit-gas-price").value, "3");
    assert.equal(harness.get("button-approve").disabled, false);
    assert.equal(Object.hasOwn(controller.state.review.account, "icon"), false);
    assert.deepEqual(normalized(response), before);
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
        harness.setState(request, response);

        await harness.boot();

        assert.equal((harness.controller.presentationActivity.kind === "failed"), true);
        assert.equal(harness.controller.state, null);
        assert.equal(harness.get("request-error").textContent, "Failed to load");
        assert.equal(harness.get("button-approve").textContent, "Refresh");
        assert.equal(harness.get("button-reject").disabled, true);
        harness.clearMessages();

        await harness.get("button-approve").click();

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

        await harness.controller.approve({
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
        assert.equal(harness.followUpTimerId(), null);
        assert.equal(harness.controller.state.state, "review");
    }
});

test("controller errors explicitly retry the visible request without entering the queue", async () => {
    const harness = await reviewedPopup();
    const controller = harness.controller;
    controller.adoptState({id: controller.request.id, state: "error", actions: ["retry"], error: "Failed"});
    assert.equal(harness.get("button-approve").disabled, false);
    assert.equal(harness.get("button-approve").textContent, "Refresh");
    assert.equal(harness.get("button-reject").disabled, true);
    assert.equal(harness.followUpTimerId(), null);

    await harness.get("button-approve").click();

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

test("decisions adopt their current reply immediately without rereading or resubmitting", async () => {
    for (const status of ["ok", "ignored"]) {
        const harness = await reviewedPopup();
        const controller = harness.controller;
        const fresh = messageState(controller.request, {
            title: "Current review", reviewToken: requestToken(102),
        });
        harness.handlers.worker = (message, fallback) => message.subject === "approveRequestWithCurrentRevisions"
            ? commandReply(fresh, status) : fallback(message);

        await controller.approve({});
        await flushPopup();

        assert.equal(harness.get("request-title").textContent, "Current review");
        assert.equal(controller.state.review.reviewToken, requestToken(102));
        assert.equal(controller.isSubmitting, false);
        assert.equal((controller.presentationActivity.kind === "failed"), false);
        assert.equal(harness.get("working-overlay").classList.contains("hidden"), true);
        assert.equal(harness.followUpTimerId(), null);
        assert.deepEqual(harness.nativeMessages, []);
        assert.equal(harness.workerMessages.length, 1);
    }
});

test("a completed decision immediately reconciles and acknowledges its durable response", async () => {
    const harness = await reviewedPopup();
    const controller = harness.controller;
    harness.handlers.worker = (message, fallback) => {
        if (message.subject !== "approveRequestWithCurrentRevisions") { return fallback(message); }
        harness.model.requests = [];
        harness.model.completed = [{
            ...completedResponse(controller.request.id),
            requestToken: controller.request.requestToken,
        }];
        return commandReply({id: controller.request.id, state: "missing", actions: []});
    };

    await controller.approve({});
    await flushPopup();

    assert.equal(controller.activity.kind, "disposed");
    assert.deepEqual(harness.model.completed, []);
    assert.equal(harness.followUpTimerId(), null);
    assert.ok(harness.nativeMessages.every(message => message.subject === "getPendingRequests"));
    assert.deepEqual(harness.workerMessages.filter(message =>
        ["approveRequestWithCurrentRevisions", "applyCompletedResponse", "responseReady"].includes(message.subject)
    ).map(message => message.subject), ["approveRequestWithCurrentRevisions", "applyCompletedResponse", "responseReady"]);
});

test("unavailable approval storage retains the request instead of reconciling a false completion", async () => {
    const harness = await reviewedPopup();
    const controller = harness.controller;
    harness.handlers.native = (message, fallback) => message.subject === "getApprovalState"
        ? commandReply(null, "unavailable") : fallback(message);

    await controller.readState();
    await flushPopup();

    assert.equal(controller.isActive, true);
    assert.equal((controller.presentationActivity.kind === "failed"), true);
    assert.equal(harness.get("button-approve").textContent, "Refresh");
    assert.deepEqual(harness.nativeMessages.map(message => message.subject), ["getApprovalState"]);
    assert.deepEqual(harness.workerMessages, []);
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
    assert.equal(harness.followUpTimerId(), null);

    await harness.get("button-reject").click();

    assert.deepEqual(harness.workerMessages, []);
    assert.deepEqual(harness.nativeMessages, [{
        subject: "rejectRequest",
        id: controller.request.id,
        workflowVersion: 3,
        requestToken: controller.request.requestToken,
        __bwPrivateBrowsing: false,
    }]);
    assert.equal(harness.followUpTimerId(), null);
    assert.equal(controller.state.state, "review");
});

test("secure setup errors allow Refresh and Cancel advances to the next request", async () => {
    const first = pendingRequest();
    const second = {...pendingRequest(8, 2), sequence: 1};
    const harness = popupHarness({requests: [first, second]});
    const error = "Open Big Wallet to finish setting up secure approvals.";
    harness.setState(first, {
        id: first.id,
        host: first.host,
        state: "error",
        actions: ["retry", "reject"],
        error,
    });
    harness.setState(second, messageState(second, {title: "Next request"}));
    await harness.boot();
    harness.clearMessages();

    assert.equal(harness.get("request-error").textContent, error);
    assert.equal(harness.get("button-approve").textContent, "Refresh");
    assert.equal(harness.get("button-approve").disabled, false);
    assert.equal(harness.get("button-reject").disabled, false);
    await harness.get("button-approve").click();
    await flushPopup();
    assert.deepEqual(harness.nativeMessages.map(message => message.subject), ["retryApproval"]);
    assert.equal(harness.get("button-approve").disabled, false);
    assert.equal(harness.get("button-reject").disabled, false);

    harness.clearMessages();
    harness.handlers.native = (message, fallback) => {
        if (message.subject !== "rejectRequest") { return fallback(message); }
        harness.model.requests = [second];
        return commandReply({id: first.id, state: "missing", actions: []});
    };
    await harness.get("button-reject").click();
    await flushPopup();

    assert.deepEqual(harness.nativeMessages.map(message => message.subject), [
        "rejectRequest", "getPendingRequests", "getApprovalState",
    ]);
    assert.equal(harness.nativeMessages[0].requestToken, first.requestToken);
    assert.equal(harness.controller.request.requestToken, second.requestToken);
    assert.equal(harness.get("request-title").textContent, "Next request");
    assert.equal(harness.model.closed, 0);
});

test("approval polling adopts an error and stops its only follow-up timer", async () => {
    const harness = await reviewedPopup();
    const controller = harness.controller;
    harness.setState(controller.request, {id: controller.request.id, state: "error", actions: ["retry"], error: "Failed"});
    controller.adoptState({id: controller.request.id, state: "working", actions: []});
    controller.scheduleRead();

    await harness.fire(harness.followUpTimerId());

    assert.equal(controller.state.state, "error");
    assert.equal((controller.presentationActivity.kind === "failed"), false);
    assert.equal(harness.get("request-error").textContent, "Failed");
    assert.equal(harness.get("working-overlay").classList.contains("hidden"), true);
    assert.equal(harness.followUpTimerId(), null);
    assert.equal(harness.timers.size, 0);
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
        const decision = controller[subject === "approveRequest" ? "approve" : "reject"](subject === "approveRequest" ? {} : undefined);
        await flushPopup();
        assert.equal(controller.isSubmitting, true);
        assert.equal(harness.followUpTimerId(), null);
        assert.equal(harness.get("button-reject").disabled, subject === "approveRequest");

        readGate.resolve(commandReply(messageState(controller.request, {reviewToken: requestToken(999), title: "Stale"})));
        await refresh;

        assert.equal(controller.state.review.reviewToken, requestToken(101));
        assert.equal(harness.get("request-title").textContent, "Sign message");
        assert.equal(harness.get("button-reject").disabled, subject === "approveRequest");
        assert.equal(harness.followUpTimerId(), null);
        actionGate.resolve(commandReply({id: controller.request.id, state: "working", actions: []}));
        await decision;
        assert.equal(harness.timers.get(harness.followUpTimerId()).delay, 400);
    }
});

test("replacement with the same numeric id disposes old reads actions and mutations", async () => {
    for (const operation of ["read", "approval", "mutation", "speed"]) {
        const harness = await reviewedPopup(transactionState);
        const first = harness.controller;
        const originalTimer = harness.followUpTimerId();
        const replacement = pendingRequest(first.request.id, 2);
        const gate = deferred();
        harness.handlers.native = (message, fallback) => {
            if (message.requestToken === first.request.requestToken) {
                const subject = operation === "read" ? "getApprovalState"
                    : operation === "speed" ? "setTransactionSpeed" : "applyTransactionEdits";
                if (message.subject === subject) { return gate.promise; }
            }
            return fallback(message);
        };
        harness.handlers.worker = (message, fallback) =>
            operation === "approval" && message.subject === "approveRequestWithCurrentRevisions"
                ? gate.promise : fallback(message);
        if (operation === "mutation") {
            harness.get("tx-editor").open = true;
            harness.get("tx-editor").emit("toggle");
        }
        const pending = operation === "read" ? first.readState({refresh: true})
            : operation === "approval" ? first.approve({})
            : operation === "speed"
                ? first.setSpeed({interaction: "ended", value: 145}, requestToken(101))
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

        gate.resolve(commandReply(transactionState(first.request, {
            title: "Late A",
            reviewToken: requestToken(999),
            alert: {title: "Old alert", message: "", actions: [{title: "Cancel", action: "cancel"}]},
        })));
        await pending;
        await flushPopup();

        assert.equal(first.activity.kind, "disposed");
        assert.equal(first.isActive, false);
        assert.equal(harness.timers.has(originalTimer), false);

        assert.equal(harness.controller, second);
        assert.equal(second.request.requestToken, replacement.requestToken);
        assert.equal(second.state.review.reviewToken, requestToken(202));
        assert.equal(harness.get("request-title").textContent, "Replacement B");
        assert.equal(harness.focusCalls.length, focusCount);
        assert.ok(!harness.textWrites.slice(writeCount).some(write => write.text === "Late A"));
        if (operation !== "read") { assert.deepEqual(harness.visibleSnapshot(), before); }
        assert.equal(harness.timers.size, 1);
        assert.ok(harness.timers.has(harness.followUpTimerId()));
    }
});

test("state transitions own one follow-up timer and ignore stale callbacks", async () => {
    const harness = await reviewedPopup(transactionState);
    const controller = harness.controller;
    const initial = harness.followUpTimerId();
    const old = harness.timers.get(initial);
    controller.scheduleRead();
    controller.scheduleRead();
    assert.notEqual(harness.followUpTimerId(), null);
    assert.equal(old.delay, 600);
    controller.adoptState({id: controller.request.id, state: "working", actions: []});
    const current = harness.followUpTimerId();
    assert.equal(harness.timers.size, 1);
    assert.equal(harness.timers.get(current).delay, 400);

    old.callback();
    await flushPopup();

    assert.equal(harness.followUpTimerId(), current);
    assert.equal(harness.nativeMessages.length, 0);
    harness.setState(controller.request, {id: controller.request.id, state: "working", actions: []});
    await harness.fire(current);
    assert.equal(harness.timers.size, 1);
    assert.equal(harness.timers.get(harness.followUpTimerId()).delay, 400);
    harness.setState(controller.request, transactionState(controller.request));
    await harness.fire(harness.followUpTimerId());
    assert.equal(harness.timers.size, 1);
    assert.equal(harness.timers.get(harness.followUpTimerId()).delay, 600);
    const last = harness.timers.get(harness.followUpTimerId());
    controller.dispose();
    last.callback();
    assert.equal(harness.followUpTimerId(), null);
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

    const completion = controller.reconcile();
    const repeated = controller.reconcile();
    await flushPopup();

    assert.equal(completion, repeated);
    assert.equal(controller.activity.kind, "reconciling");
    assert.equal(controller.isActive, false);
    assert.equal(harness.queue.canRefresh, true);
    assert.deepEqual(harness.nativeMessages.map(message => message.subject), ["getPendingRequests"]);
    gate.resolve({completedResponses: [], requests: [replacement]});
    await completion;
    await flushPopup();
    assert.equal(controller.activity.kind, "disposed");
    assert.equal(harness.controller.request.requestToken, replacement.requestToken);
    assert.equal(harness.get("request-title").textContent, "Replacement B");
    assert.equal(harness.model.closed, 0);
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
    assert.ok(harness.queue.tab.recoveryTab);
    assert.equal(harness.tabMessages.length, 1);

    harness.model.requests = [];
    await harness.controller.reconcile();

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
    assert.equal((controller.activity.kind === "dragging"), true);
    assert.equal(harness.get("button-approve").disabled, true);
    await controller.approveCurrent();
    await controller.approve({});
    assert.deepEqual(harness.nativeMessages, []);
    assert.deepEqual(harness.workerMessages, []);
    slider.emit("change");
    await flushPopup();
    assert.equal(slider.disabled, true);
    assert.equal(harness.get("button-approve").disabled, true);
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

    gate.resolve(commandReply(transactionState(controller.request, {
        reviewToken: requestToken(102),
        slider: {maximum: 200, position: 145, visible: true},
    })));
    await flushPopup();
    assert.equal(controller.isSubmitting, false);
    assert.equal(harness.get("button-approve").disabled, false);
    assert.deepEqual(harness.workerMessages, []);
    assert.equal(controller.state.review.reviewToken, requestToken(102));
    assert.equal(harness.timers.get(harness.followUpTimerId()).delay, 600);
    assert.equal(Number(slider.value), 145);
});

test("approval requires a fresh click after the drag result is displayed", async () => {
    const harness = await reviewedPopup(transactionState);
    const controller = harness.controller;
    const gate = deferred();
    harness.handlers.native = (message, fallback) =>
        message.subject === "setTransactionSpeed" ? gate.promise : fallback(message);
    const slider = harness.get("tx-slider");
    slider.emit("pointerdown");
    assert.equal(harness.get("button-approve").disabled, true);
    slider.value = "160";
    slider.emit("input");
    await harness.get("button-approve").click();
    await controller.approve({});
    assert.deepEqual(harness.nativeMessages, []);
    slider.emit("pointerup");
    slider.emit("change");
    await flushPopup();
    assert.equal(harness.get("button-approve").disabled, true);
    await controller.approveCurrent();
    await controller.approve({});
    assert.deepEqual(harness.nativeMessages.map(message => message.subject), ["setTransactionSpeed"]);
    assert.deepEqual(harness.workerMessages, []);

    gate.resolve(commandReply(transactionState(controller.request, {title: "Updated fee review", reviewToken: requestToken(102)})));
    await flushPopup();
    assert.equal(harness.get("request-title").textContent, "Updated fee review");
    assert.equal(harness.get("button-approve").disabled, false);
    assert.deepEqual(harness.workerMessages, []);
    await harness.get("button-approve").click();

    assert.equal(harness.workerMessages[0].subject, "approveRequestWithCurrentRevisions");
    assert.equal(harness.workerMessages[0].reviewToken, requestToken(102));
    assert.equal(harness.timers.get(harness.followUpTimerId()).delay, 600);
    slider.emit("pointerup");
    slider.emit("change");
    await flushPopup();
    assert.equal(harness.nativeMessages.filter(message => message.subject === "setTransactionSpeed").length, 1);
    assert.equal(harness.workerMessages.length, 1);
});

test("stale or ignored terminal slider commands block approval until a fresh review is displayed", async () => {
    for (const stale of [true, false]) {
        const harness = await reviewedPopup(transactionState);
        const controller = harness.controller;
        const fresh = transactionState(controller.request, {reviewToken: requestToken(102)});
        const gate = deferred();
        harness.setState(controller.request, fresh);
        harness.handlers.native = (message, fallback) =>
            message.subject === "setTransactionSpeed" || message.subject === "getApprovalState"
                ? gate.promise : fallback(message);
        const slider = harness.get("tx-slider");
        slider.emit("pointerdown");
        slider.value = "140";
        if (stale) { controller.adoptState(fresh); }

        const completion = controller.finishSliderInteraction("ended");
        await flushPopup();
        assert.equal(harness.get("button-approve").disabled, true);
        await controller.approveCurrent();
        await controller.approve({});

        assert.deepEqual(harness.nativeMessages.map(message => message.subject), stale
            ? ["getApprovalState"] : ["setTransactionSpeed"]);
        assert.deepEqual(harness.workerMessages, []);
        gate.resolve(commandReply(fresh, stale ? "ok" : "ignored"));
        assert.equal(await completion, false);
        assert.equal(controller.state.review.reviewToken, requestToken(102));
        assert.equal(controller.isSubmitting, false);
        assert.equal(harness.get("button-approve").disabled, false);
        assert.equal(harness.timers.get(harness.followUpTimerId()).delay, 600);
        assert.deepEqual(harness.workerMessages, []);
        await harness.get("button-approve").click();
        assert.equal(harness.workerMessages[0].reviewToken, requestToken(102));
    }
});

test("unavailable fee-review state follows transport recovery without approving", async () => {
    const harness = await reviewedPopup(transactionState);
    const controller = harness.controller;
    harness.handlers.native = (message, fallback) => {
        if (message.subject === "setTransactionSpeed") { return commandReply(null, "unavailable"); }
        if (message.subject === "getApprovalState") { throw new Error("Native unavailable"); }
        return fallback(message);
    };

    assert.equal(await controller.setSpeed({interaction: "ended", value: 145}, requestToken(101)), false);

    assert.equal((controller.presentationActivity.kind === "failed"), true);
    assert.equal(controller.isSubmitting, false);
    assert.equal(harness.get("request-error").textContent, "Failed to load");
    assert.equal(harness.get("button-approve").textContent, "Refresh");
    await controller.approve({});
    assert.deepEqual(harness.workerMessages, []);
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
        message.subject === "setTransactionSpeed" ? commandReply(fresh) : fallback(message);
    await harness.show([replacement]);
    harness.clearMessages();

    slider.emit("input");
    slider.emit("pointerup");
    slider.emit("change");
    await flushPopup();

    assert.equal(first.activity.kind, "disposed");
    assert.equal((harness.controller.activity.kind === "dragging"), false);
    assert.deepEqual(harness.nativeMessages, []);
    slider.emit("pointerdown");
    slider.value = "180";
    slider.emit("pointercancel");
    await flushPopup();
    assert.equal(harness.controller.isSubmitting, false);
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
        const completion = controller.setSpeed({interaction: "ended", value: 145}, controller.state.review.reviewToken);
        await flushPopup();
        harness.get("tx-slider").value = "145";
        const before = harness.visibleSnapshot();

        await controller.readState({refresh: true});

        assert.deepEqual(harness.visibleSnapshot(), before);
        assert.equal(controller.state.review.title, "Send transaction");
        gate.resolve(commandReply(refreshed));
        assert.equal(await completion, true);
        assert.equal(harness.get("request-title").textContent, refreshed.review.title);
    }
});

test("Apply and Reset clear drafts so subsequent native values populate every field", async () => {
    for (const button of ["editor-apply", "editor-suggested"]) {
        const editor = {
            usesEIP1559: true, nonce: "1",
            maxPriorityFeePerGasGwei: "2", maxFeePerGasGwei: "22",
            suggestedMaxPriorityFeePerGasGwei: "3", suggestedMaxFeePerGasGwei: "23",
        };
        const harness = await reviewedPopup(request => transactionState(request, {editor}));
        const controller = harness.controller;
        harness.get("tx-editor").open = true;
        harness.get("tx-editor").emit("toggle");
        harness.get("edit-nonce").value = "9";
        harness.get("edit-nonce").emit("input");
        harness.get("edit-max-priority").value = "5";
        harness.get("edit-max-priority").emit("input");
        harness.handlers.native = (message, fallback) => message.subject === "applyTransactionEdits"
            ? commandReply(transactionState(controller.request, {editor, reviewToken: requestToken(102)}))
            : fallback(message);

        await harness.get(button).click();

        assert.equal(harness.get("tx-editor").open, false);
        assert.equal(["editing", "dragging"].includes(controller.activity.kind), false);
        assert.equal(harness.get("edits-error").classList.contains("hidden"), true);
        if (button === "editor-suggested") {
            assert.deepEqual(harness.nativeMessages.at(-1).payload, {mode: "suggested"});
        }
        harness.setState(controller.request, transactionState(controller.request, {
            editor: {...editor, nonce: "2", maxPriorityFeePerGasGwei: "4", maxFeePerGasGwei: "24"},
            reviewToken: requestToken(103),
        }));

        await controller.readState({refresh: true});

        assert.equal(harness.get("edit-nonce").value, "2");
        assert.equal(harness.get("edit-max-priority").value, "4");
        assert.equal(harness.get("edit-max-fee").value, "24");
    }
});

test("an edit error preserves the open editor and typed values", async () => {
    const harness = await reviewedPopup(transactionState);
    const controller = harness.controller;
    harness.get("tx-editor").open = true;
    harness.get("tx-editor").emit("toggle");
    harness.get("edit-nonce").value = "invalid";
    harness.get("edit-nonce").emit("input");
    harness.handlers.native = (message, fallback) => message.subject === "applyTransactionEdits"
        ? commandReply(transactionState(controller.request, {}, {editsError: true})) : fallback(message);

    await harness.get("editor-apply").click();

    assert.equal(harness.get("tx-editor").open, true);
    assert.equal(harness.get("edit-nonce").value, "invalid");
    assert.equal(harness.get("edits-error").classList.contains("hidden"), false);
    assert.equal(controller.activity.kind, "editing");
    assert.equal(harness.followUpTimerId(), null);

    harness.setState(controller.request, transactionState(controller.request, {
        editor: {...controller.state.review.editor, gasPriceGwei: "4", nonce: "2"},
        reviewToken: requestToken(102),
    }));
    await controller.readState({refresh: true});

    assert.equal(harness.get("tx-editor").open, true);
    assert.equal(harness.get("edit-nonce").value, "invalid");
    assert.equal(harness.get("edit-gas-price").value, "2");
    assert.equal(harness.get("edits-error").classList.contains("hidden"), false);
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
    gate.resolve(commandReply(transactionState(controller.request, {reviewToken: requestToken(999)})));
    await clicked;
    assert.equal(controller.state.review.reviewToken, requestToken(102));
    assert.equal(harness.get("alert-overlay").classList.contains("hidden"), false);
    assert.equal(harness.get("alert-title").textContent, "Review fees");
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
    const timer = harness.followUpTimerId();

    gate.resolve(commandReply(transactionState(first.request)));
    await clicked;
    await button.emit("click");
    await flushPopup();

    assert.deepEqual(harness.visibleSnapshot(), before);
    assert.equal(harness.focusCalls.length, focusCount);
    assert.notEqual(harness.followUpTimerId(), null);
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
    await harness.get("button-approve").click();
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
    await harness.get("button-approve").click();
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

        harness.get("edit-nonce").value = "9";
        harness.get("edit-nonce").emit("input");
        harness.setState(controller.request, {id: controller.request.id, state, actions: []});
        await controller.readState();
        assert.equal(controller.state.review, undefined);
        assert.equal(harness.get("request-title").textContent, "Send transaction");
        assert.deepEqual(harness.get("tx-fee-lines").children, feeRows);
        assert.equal(harness.get("tx-editor").open, false);
        assert.equal(harness.get("edit-nonce").value, controller.state.review ? "2" : "9");
        assert.equal(["editing", "dragging"].includes(controller.activity.kind), false);
        assert.equal(harness.get("button-approve").disabled, true);
        assert.equal(harness.get("button-reject").disabled, true);
        assert.equal(harness.get("tx-slider").disabled, true);
        assert.equal(harness.get("editor-apply").disabled, true);
        assert.equal(harness.get("working-overlay").classList.contains("hidden"), false);
        assert.equal(harness.get("screen-request").inert, true);
        assert.equal(harness.timers.get(harness.followUpTimerId()).delay, 400);
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
        assert.equal(harness.get("tx-editor").open, false);
        assert.equal(harness.get("edit-nonce").value, controller.state.review ? "2" : "9");
        assert.equal(["editing", "dragging"].includes(controller.activity.kind), false);
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
    await harness.failTransport(controller);
    const retry = controller.retry();
    await flushPopup();
    readGate.resolve(commandReply(messageState(controller.request, {title: "Old review"})));
    await oldRead;
    assert.equal((controller.presentationActivity.kind === "failed"), true);
    assert.equal(controller.isSubmitting, true);
    assert.equal(harness.get("working-overlay").classList.contains("hidden"), true);
    retryGate.resolve(commandReply(messageState(controller.request, {title: "Fresh review", reviewToken: requestToken(202)})));
    await retry;
    assert.equal(harness.get("request-title").textContent, "Fresh review");
    assert.equal(controller.state.review.reviewToken, requestToken(202));
    assert.deepEqual(harness.nativeMessages.map(message => message.subject), ["getApprovalState", "retryApproval"]);
    assert.equal(Object.hasOwn(harness.nativeMessages[1], "reviewToken"), false);
    assert.equal(Object.hasOwn(harness.nativeMessages[1], "payload"), false);
    assert.equal(harness.followUpTimerId(), null);
});

test("retry follows busy states and reconciles missing requests", async () => {
    for (const state of ["working", "missing"]) {
        const harness = await reviewedPopup();
        const controller = harness.controller;
        await harness.failTransport(controller);
        harness.handlers.native = (message, fallback) => {
            if (message.subject === "retryApproval") {
                if (state === "missing") { harness.model.requests = []; }
                return commandReply({id: message.id, state, actions: []});
            }
            return fallback(message);
        };
        await controller.retry();
        await flushPopup();
        if (state === "working") {
            assert.equal(controller.state.state, "working");
            assert.equal(harness.timers.get(harness.followUpTimerId()).delay, 400);
            assert.equal(harness.get("working-overlay").classList.contains("hidden"), false);
        } else {
            assert.equal(controller.activity.kind, "disposed");
            assert.equal(harness.followUpTimerId(), null);
            assert.equal(harness.model.closed, 1);
        }
    }
});

test("late idle switch replies preserve preparing and working requests", async () => {
    for (const busy of [false, true]) {
        for (const outcome of ["acknowledged", "transport failure", "terminal error"]) {
            const succeeds = outcome === "acknowledged";
            const intent = deferred();
            const harness = popupHarness({tab: () => intent.promise});
            await harness.boot();
            const switching = harness.queue.switchAccountFromIdle();
            await flushPopup();
            const switchTimeout = [...harness.timers.values()].find(timer => timer.delay === 10_000);
            assert.ok(switchTimeout);
            const request = pendingRequest();
            harness.model.requests = [request];
            harness.setState(request, busy
                ? {id: request.id, state: "working", actions: []}
                : transactionState(request, {phase: "preparing"}, {actions: ["reject"]}));
            harness.notify();
            await harness.fire(harness.queue.refresh.timer);
            const controller = harness.controller;
            const timer = harness.followUpTimerId([switchTimeout.id]);
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
            } else if (outcome === "terminal error") {
                intent.resolve(nativeError({
                    id: 8, name: "switchAccount", provider: "multiple",
                    error: {code: -32603, message: "Too many account switches are pending. Finish one, then try again."},
                }));
            } else {
                intent.reject(new Error("Late transport failure"));
            }
            await switching;
            await flushPopup();
            assert.equal(harness.controller, controller);
            assert.notEqual(harness.followUpTimerId(), null);
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
            await harness.fire(harness.followUpTimerId());
            assert.equal(controller.activity.kind, "disposed");
            if (succeeds) {
                assert.equal(harness.controller.request.requestToken, next.requestToken);
            } else {
                assert.equal(harness.model.closed, 1);
            }
        }
    }
});

test("reordered approval object keys preserve DOM nodes and transaction backoff", async () => {
    function reverseObjectKeys(value) {
        if (Array.isArray(value)) { return value.map(reverseObjectKeys); }
        if (value !== null && typeof value === "object") {
            return Object.fromEntries(Object.entries(value).reverse().map(([key, item]) =>
                [key, reverseObjectKeys(item)]
            ));
        }
        return value;
    }
    const harness = await reviewedPopup(request => transactionState(request, {
        phase: "reviewingFees",
        alert: {
            title: "Review fees",
            message: "Updated estimate",
            actions: [{title: "OK", action: "acknowledge"}],
        },
    }, {actions: ["reject", "resolveApprovalAlert"]}));
    const controller = harness.controller;
    const original = normalized(controller.state);
    const reordered = reverseObjectKeys(original);
    const originalJSON = JSON.stringify(original);
    const reorderedJSON = JSON.stringify(reordered);
    assert.notEqual(originalJSON, reorderedJSON);
    assert.notDeepEqual(Object.keys(original.review.alert.actions[0]), Object.keys(reordered.review.alert.actions[0]));
    const feeRow = harness.get("tx-fee-lines").children[0];
    const accountName = harness.get("tx-account").children[0];
    const alertButton = harness.get("alert-buttons").children[0];
    const writes = harness.textWrites.length;

    for (const [index, delay] of [1200, 2400, 4800, 9600, 10000, 10000].entries()) {
        harness.setState(controller.request, index % 2 === 0 ? reordered : original);
        await harness.fire(harness.followUpTimerId());

        assert.equal(harness.get("tx-fee-lines").children[0], feeRow);
        assert.equal(harness.get("tx-account").children[0], accountName);
        assert.equal(harness.get("alert-buttons").children[0], alertButton);
        assert.equal(harness.textWrites.length, writes);
        assert.equal(harness.timers.get(harness.followUpTimerId()).delay, delay);
    }
    assert.equal(JSON.stringify(original), originalJSON);
    assert.equal(JSON.stringify(reordered), reorderedJSON);
});

test("meaningful approval changes still redraw and reset transaction backoff", async () => {
    const changes = [
        state => { state.review.valueLine = "Changed value"; },
        state => { state.review.reviewToken = requestToken(102); },
        state => { state.actions = state.actions.filter(action => action !== "setTransactionSpeed"); },
        state => { state.review.phase = "preparing"; state.actions = ["reject"]; },
        state => { state.review.feeLines.reverse(); },
    ];
    for (const change of changes) {
        const harness = await reviewedPopup(request => transactionState(request, {
            feeLines: ["Network fee: 0.001 ETH", "Maximum fee: 0.002 ETH"],
        }));
        const controller = harness.controller;
        await harness.fire(harness.followUpTimerId());
        await harness.fire(harness.followUpTimerId());
        assert.equal(harness.timers.get(harness.followUpTimerId()).delay, 2400);
        const previousFeeRow = harness.get("tx-fee-lines").children[0];
        const changed = normalized(controller.state);
        change(changed);
        harness.setState(controller.request, changed);

        await harness.fire(harness.followUpTimerId());

        assert.notEqual(harness.get("tx-fee-lines").children[0], previousFeeRow);
        assert.equal(harness.timers.get(harness.followUpTimerId()).delay, 600);
        assert.deepEqual(normalized(controller.state), changed);
    }
});

test("state reads coalesce and transaction polling preserves its backoff", async () => {
    const harness = await reviewedPopup(transactionState);
    const controller = harness.controller;
    const gate = deferred();
    harness.handlers.native = (message, fallback) =>
        message.subject === "getApprovalState" ? gate.promise : fallback(message);
    await harness.fire(harness.followUpTimerId());
    const duplicate = controller.readState({refresh: true});
    controller.scheduleRead();
    controller.scheduleRead();
    await flushPopup();
    assert.equal(harness.nativeMessages.length, 1);
    assert.equal(harness.followUpTimerId(), null);
    gate.resolve(commandReply(transactionState(controller.request)));
    await duplicate;
    harness.handlers.native = undefined;
    for (const delay of [1200, 2400, 4800, 9600, 10000, 10000]) {
        const timer = harness.followUpTimerId();
        assert.equal(harness.timers.get(timer).delay, delay);
        controller.scheduleRead();
        assert.notEqual(harness.followUpTimerId(), null);
        await harness.fire(harness.followUpTimerId());
    }
    harness.setState(controller.request, transactionState(controller.request, {valueLine: "Changed value"}));
    await harness.fire(harness.followUpTimerId());
    assert.equal(harness.timers.get(harness.followUpTimerId()).delay, 600);
    harness.setState(controller.request, transactionState(controller.request, {phase: "preparing"}, {actions: ["reject"]}));
    await harness.fire(harness.followUpTimerId());
    assert.equal(harness.timers.get(harness.followUpTimerId()).delay, 600);
    harness.setState(controller.request, {id: controller.request.id, state: "authenticating", actions: []});
    await harness.fire(harness.followUpTimerId());
    assert.equal(harness.timers.get(harness.followUpTimerId()).delay, 400);
    harness.setState(controller.request, transactionState(controller.request));
    await harness.fire(harness.followUpTimerId());
    assert.equal(harness.timers.get(harness.followUpTimerId()).delay, 600);
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
            assert.ok(harness.queue.tab.recoveryTab);
            const originalTab = harness.queue.tab.activeTab;
            const recoveryTab = harness.queue.tab.recoveryTab;
            const gate = deferred();
            let reloads = 0;
            harness.browser.tabs.reload = () => {
                reloads += 1;
                return stage === "reload" ? gate.promise : Promise.resolve();
            };
            if (stage === "query") { harness.browser.tabs.query = () => gate.promise; }
            if (stage === "probe") { harness.handlers.tab = () => gate.promise; }
            const refreshing = harness.queue.refreshIdleStatus();
            await flushPopup();
            const request = pendingRequest();
            harness.model.requests = [request];
            harness.setState(request, {id: request.id, state: "working", actions: []});
            harness.notify();
            await harness.fire(harness.queue.refresh.timer);
            const controller = harness.controller;
            const timer = harness.followUpTimerId();
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
            assert.equal(harness.queue.tab.activeTab, originalTab);
            assert.equal(harness.queue.tab.recoveryTab, recoveryTab);
            assert.equal(harness.controller, controller);
            assert.notEqual(harness.followUpTimerId(), null);
            assert.equal(harness.get("screen-loading").classList.contains("hidden"), true);
            harness.setState(request, transactionState(request));
            await harness.fire(timer);
            assert.equal(harness.get("button-approve").disabled, false);
        }
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
            const oldRefresh = harness.queue.refreshIdleStatus();
            await flushPopup();
            const oldProbe = harness.tabMessages.at(-1).message;
            assert.equal(harness.get("idle-check-status").disabled, true);
            harness.notify();
            await harness.fire(harness.queue.refresh.timer);
            assert.equal(harness.queue.isEmpty, true);
            assert.equal(harness.get("screen-idle").classList.contains("hidden"), false);
            assert.equal(harness.get("idle-check-status").disabled, false);

            const nextGate = deferred();
            harness.browser.tabs.query = () => nextGate.promise;
            harness.handlers.tab = probe;
            harness.browser.tabs.reload = async () => { reloads += 1; };
            const nextRefresh = harness.queue.refreshIdleStatus();
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

test("queued selection callbacks cannot replace a transport error with the retained review", async () => {
    for (const kind of ["account", "cluster"]) {
        const harness = await reviewedPopup(kind === "account" ? selectionState : request => messageState(request, {
            clusters: [{value: "devnet", label: "Devnet", isSelected: false}],
            requiresClusterSelection: true,
        }));
        const controller = harness.controller;
        const row = harness.get(kind === "account" ? "accounts-list" : "clusters").children[0];
        const snapshot = controller.state;
        const selection = JSON.stringify(controller.presentation.accounts);
        const cluster = controller.presentation.cluster;
        await harness.failTransport(controller);
        const failedUI = harness.visibleSnapshot();

        await row.emit("click");

        assert.deepEqual(harness.visibleSnapshot(), failedUI);
        assert.equal(controller.state, snapshot);
        assert.equal(JSON.stringify(controller.presentation.accounts), selection);
        assert.equal(controller.presentation.cluster, cluster);
        assert.equal((controller.presentationActivity.kind === "failed"), true);
        assert.equal(harness.get("button-approve").textContent, "Refresh");
        assert.deepEqual(harness.nativeMessages, []);
        assert.deepEqual(harness.workerMessages, []);
    }
});

test("advanced editing pauses refresh and exclusively owns a complete draft", async () => {
    const harness = await reviewedPopup(transactionState);
    const controller = harness.controller;
    const oldTimer = harness.timers.get(harness.followUpTimerId());
    harness.get("tx-editor").open = true;
    harness.get("tx-editor").emit("toggle");
    harness.get("edit-nonce").value = "9";
    harness.get("edit-nonce").emit("input");
    assert.equal(harness.followUpTimerId(), null);
    assert.equal(harness.get("button-approve").disabled, true);
    assert.equal(harness.get("tx-slider").disabled, true);
    assert.equal(harness.get("button-reject").disabled, false);
    oldTimer.callback();
    await controller.readState({refresh: true});
    await controller.approveCurrent();
    assert.equal(controller.beginSliderInteraction(), false);
    assert.deepEqual(harness.nativeMessages, []);
    assert.deepEqual(harness.workerMessages, []);
    harness.get("tx-editor").open = false;
    harness.get("tx-editor").emit("toggle");
    assert.equal(["editing", "dragging"].includes(controller.activity.kind), false);
    assert.equal(harness.timers.get(harness.followUpTimerId()).delay, 600);
    harness.get("tx-editor").open = true;
    harness.get("tx-editor").emit("toggle");
    assert.equal(harness.get("edit-nonce").value, "1");
    const result = transactionState(controller.request, {reviewToken: requestToken(102)});
    harness.handlers.native = (message, fallback) => message.subject === "applyTransactionEdits" ? commandReply(result) : fallback(message);
    harness.get("edit-nonce").value = "8";
    harness.get("edit-nonce").emit("input");
    await harness.get("editor-apply").click();
    assert.deepEqual(harness.nativeMessages[0].payload, {mode: "custom", nonce: "8", gasPriceGwei: "2"});
    assert.equal(harness.nativeMessages[0].reviewToken, requestToken(101));
    assert.equal(harness.get("tx-editor").open, false);
    assert.equal(harness.get("button-approve").disabled, false);
    assert.equal(harness.get("tx-slider").disabled, false);
    assert.notEqual(harness.followUpTimerId(), null);
});

test("Advanced activation fences a pending read before the delayed toggle event", async () => {
    const harness = await reviewedPopup(transactionState);
    const controller = harness.controller;
    const editor = harness.get("tx-editor");
    const gate = deferred();
    harness.handlers.native = (message, fallback) => message.subject === "getApprovalState" ? gate.promise : fallback(message);
    const reading = controller.readState({refresh: true});
    const clickSummary = () => {
        let prevented = false;
        harness.get("tx-editor-summary").emit("click", {preventDefault() { prevented = true; }});
        if (!prevented) { editor.open = !editor.open; }
    };

    clickSummary();
    gate.resolve(commandReply(transactionState(controller.request, {reviewToken: requestToken(999)})));
    await reading;
    editor.emit("toggle");

    assert.equal(editor.open, true);
    assert.equal(controller.activity.kind, "editing");
    assert.equal(controller.state.review.reviewToken, requestToken(101));
    assert.equal(harness.get("button-approve").disabled, true);
    assert.equal(harness.followUpTimerId(), null);

    clickSummary();
    editor.emit("toggle");
    assert.equal(editor.open, false);
    assert.equal(controller.activity.kind, "viewing");
    assert.notEqual(harness.followUpTimerId(), null);
});

test("interaction start fences an already-dispatched read without adopting an unseen token", async () => {
    for (const interaction of ["editor", "slider"]) {
        const harness = await reviewedPopup(transactionState);
        const controller = harness.controller;
        const gate = deferred();
        harness.handlers.native = (message, fallback) => message.subject === "getApprovalState" ? gate.promise : fallback(message);
        const reading = controller.readState({refresh: true});
        if (interaction === "editor") {
            harness.get("tx-editor").open = true;
            harness.get("tx-editor").emit("toggle");
            harness.get("edit-nonce").value = "7";
            harness.get("edit-nonce").emit("input");
        } else {
            harness.get("tx-slider").emit("pointerdown");
            harness.get("tx-slider").value = "155";
        }
        gate.resolve(commandReply(transactionState(controller.request, {reviewToken: requestToken(999), title: "Unseen review"})));
        await reading;
        assert.equal(controller.state.review.reviewToken, requestToken(101));
        assert.equal(harness.get("request-title").textContent, "Send transaction");
        assert.equal((controller.activity.draft ?? controller.activity.gesture).reviewToken, requestToken(101));
        assert.equal(harness.followUpTimerId(), null);
        assert.equal(interaction === "editor" ? harness.get("edit-nonce").value : harness.get("tx-slider").value,
            interaction === "editor" ? "7" : "155");
    }
});

test("stale Apply adopts its reply without a read and preserves the draft for another explicit Apply", async () => {
    const harness = await reviewedPopup(transactionState);
    const controller = harness.controller;
    harness.get("tx-editor").open = true;
    harness.get("tx-editor").emit("toggle");
    harness.get("edit-nonce").value = "7";
    harness.get("edit-nonce").emit("input");
    harness.get("edit-gas-price").value = "8";
    harness.get("edit-gas-price").emit("input");
    const fresh = transactionState(controller.request, {
        reviewToken: requestToken(102),
        editor: {usesEIP1559: false, nonce: "2", gasPriceGwei: "4"},
    });
    let attempts = 0;
    harness.handlers.native = (message, fallback) => {
        if (message.subject === "getApprovalState") { return commandReply(fresh); }
        if (message.subject === "applyTransactionEdits") {
            return commandReply(fresh, ++attempts === 1 ? "ignored" : "ok");
        }
        return fallback(message);
    };
    await harness.get("editor-apply").click();
    assert.deepEqual(harness.nativeMessages.map(message => message.subject), ["applyTransactionEdits"]);
    assert.equal(harness.get("tx-editor").open, true);
    assert.equal(harness.get("edit-nonce").value, "7");
    assert.equal(harness.get("edit-gas-price").value, "8");
    assert.equal(harness.get("edits-error").textContent, "Review changed. Check the values and apply again.");
    assert.equal(harness.get("editor-apply").disabled, false);
    assert.equal(harness.get("button-approve").disabled, true);
    assert.equal(harness.followUpTimerId(), null);
    await harness.get("editor-apply").click();
    assert.equal(attempts, 2);
    assert.equal(harness.nativeMessages[1].reviewToken, requestToken(102));
    assert.deepEqual(harness.nativeMessages[1].payload, {mode: "custom", nonce: "7", gasPriceGwei: "8"});
    assert.equal(harness.get("tx-editor").open, false);
});

test("stale Apply discards a draft when recovery changes the fee model or edit capability", async () => {
    for (const changedModel of [true, false]) {
        const harness = await reviewedPopup(transactionState);
        const controller = harness.controller;
        harness.get("tx-editor").open = true;
        harness.get("tx-editor").emit("toggle");
        harness.get("edit-nonce").value = "7";
        harness.get("edit-nonce").emit("input");
        const fresh = changedModel ? transactionState(controller.request, {
            reviewToken: requestToken(102),
            editor: {usesEIP1559: true, nonce: "2", maxFeePerGasGwei: "9", maxPriorityFeePerGasGwei: "3"},
        }) : transactionState(controller.request, {reviewToken: requestToken(102)}, {actions: ["reject"]});
        harness.handlers.native = (message, fallback) => message.subject === "applyTransactionEdits"
            ? commandReply(fresh, "ignored") : fallback(message);
        await harness.get("editor-apply").click();
        assert.equal(["editing", "dragging"].includes(controller.activity.kind), false);
        assert.equal(harness.get("tx-editor").open, false);
        assert.equal(controller.state.review.reviewToken, requestToken(102));
        assert.equal(harness.nativeMessages.filter(message => message.subject === "applyTransactionEdits").length, 1);
    }
});

for (const failure of ["unavailable", "transport"]) {
    test(`${failure} edits discard the draft and retain the request until explicit Refresh`, async () => {
        const harness = await reviewedPopup(transactionState);
        const controller = harness.controller;
        harness.get("tx-editor").open = true;
        harness.get("tx-editor").emit("toggle");
        harness.get("edit-nonce").value = "7";
        harness.get("edit-nonce").emit("input");
        harness.get("edit-gas-price").value = "8";
        harness.get("edit-gas-price").emit("input");
        const fresh = transactionState(controller.request, {
            reviewToken: requestToken(102),
            editor: {usesEIP1559: false, nonce: "2", gasPriceGwei: "4"},
        });
        harness.handlers.native = (message, fallback) => {
            if (message.subject === "applyTransactionEdits") {
                if (failure === "transport") { throw new Error("Native transport failed"); }
                return commandReply(null, "unavailable");
            }
            if (message.subject === "retryApproval") { return commandReply(fresh); }
            return fallback(message);
        };

        await harness.get("editor-apply").click();
        await flushPopup();

        assert.equal(harness.controller, controller);
        assert.equal(controller.isActive, true);
        assert.equal(controller.activity.kind, "failed");
        assert.equal(controller.editorDraft, null);
        assert.equal(harness.get("tx-editor").open, false);
        assert.equal(harness.get("request-error").textContent, "Failed to load");
        assert.equal(harness.get("button-approve").textContent, "Refresh");
        assert.equal(harness.get("button-reject").disabled, true);
        assert.equal(harness.followUpTimerId(), null);
        await controller.applyEdits();
        await controller.approve({});
        assert.deepEqual(harness.nativeMessages.map(message => message.subject), ["applyTransactionEdits"]);
        assert.deepEqual(harness.workerMessages, []);

        await harness.get("button-approve").click();

        assert.deepEqual(harness.nativeMessages.map(message => message.subject), ["applyTransactionEdits", "retryApproval"]);
        assert.deepEqual(harness.workerMessages, []);
        assert.equal(controller.activity.kind, "viewing");
        assert.equal(controller.state.review.reviewToken, requestToken(102));
        assert.equal(controller.editorDraft, null);
        assert.equal(harness.get("tx-editor").open, false);
        harness.get("tx-editor").open = true;
        harness.get("tx-editor").emit("toggle");
        assert.equal(harness.get("edit-nonce").value, "2");
        assert.equal(harness.get("edit-gas-price").value, "4");
    });
}

test("queued editor input cannot change a submitted draft or its retry payload", async () => {
    const harness = await reviewedPopup(transactionState);
    const controller = harness.controller;
    harness.get("tx-editor").open = true;
    harness.get("tx-editor").emit("toggle");
    harness.get("edit-nonce").value = "7";
    harness.get("edit-nonce").emit("input");
    harness.get("edit-gas-price").value = "8";
    harness.get("edit-gas-price").emit("input");
    const gate = deferred();
    harness.handlers.native = (message, fallback) => message.subject === "applyTransactionEdits"
        ? gate.promise : fallback(message);
    const applying = harness.get("editor-apply").click();
    await flushPopup();
    harness.get("edit-nonce").value = "99";
    harness.get("edit-nonce").emit("input");
    harness.get("tx-editor").open = false;
    harness.get("tx-editor").emit("toggle");
    assert.equal(harness.get("tx-editor").open, true);
    gate.resolve(commandReply(transactionState(controller.request, {
        reviewToken: requestToken(102),
    }), "ignored"));
    await applying;
    assert.equal(harness.get("edit-nonce").value, "7");
    assert.equal(harness.get("edit-gas-price").value, "8");
    assert.equal(harness.get("button-approve").disabled, true);
    await harness.get("editor-apply").click();
    const commands = harness.nativeMessages.filter(message => message.subject === "applyTransactionEdits");
    assert.equal(commands.length, 2);
    assert.deepEqual(commands[0].payload, {mode: "custom", nonce: "7", gasPriceGwei: "8"});
    assert.deepEqual(commands[1].payload, commands[0].payload);
    assert.equal(commands[1].reviewToken, requestToken(102));
});

test("Cancel supersedes hung reads edits and speed commands without waiting", async () => {
    for (const kind of ["read", "edits", "speed"]) {
        const harness = await reviewedPopup(transactionState);
        const controller = harness.controller;
        const gate = deferred();
        harness.handlers.native = (message, fallback) => {
            if (kind === "read" && message.subject === "getApprovalState" ||
                kind === "edits" && message.subject === "applyTransactionEdits" ||
                kind === "speed" && message.subject === "setTransactionSpeed") { return gate.promise; }
            return fallback(message);
        };
        let pending;
        if (kind === "read") { pending = controller.readState(); }
        else if (kind === "speed") { pending = controller.setSpeed({interaction: "ended", value: 130}, requestToken(101)); }
        else {
            harness.get("tx-editor").open = true;
            harness.get("tx-editor").emit("toggle");
            harness.get("edit-nonce").value = "8";
            harness.get("edit-nonce").emit("input");
            pending = harness.get("editor-apply").click();
        }
        await flushPopup();
        if (kind === "edits") {
            assert.equal(harness.get("edit-nonce").disabled, true);
            harness.get("tx-editor").open = false;
            harness.get("tx-editor").emit("toggle");
            assert.equal(harness.get("tx-editor").open, true);
        }
        assert.equal(harness.get("button-reject").disabled, false);
        assert.equal(harness.get("working-overlay").classList.contains("hidden"), true);
        assert.equal(harness.get("screen-request").inert, false);
        await harness.get("button-reject").click();
        assert.equal(harness.nativeMessages.at(-1).subject, "rejectRequest");
        const timer = harness.followUpTimerId();
        const snapshot = harness.visibleSnapshot();
        gate.resolve(commandReply(transactionState(controller.request, {title: "Late mutation", reviewToken: requestToken(999)})));
        await pending;
        assert.equal(controller.isSubmitting, false);
        assert.equal(harness.followUpTimerId(), timer);
        assert.deepEqual(harness.visibleSnapshot(), snapshot);
    }
});

test("a hung approval disables Cancel without blocking replacement requests", async () => {
    const harness = await reviewedPopup(transactionState);
    const original = harness.controller;
    const gate = deferred();
    harness.handlers.worker = (message, fallback) => message.subject === "approveRequestWithCurrentRevisions" ? gate.promise : fallback(message);
    const approving = original.approveCurrent();
    await flushPopup();
    assert.equal(harness.timerHistory.at(-1).delay, 190_000);
    assert.equal(harness.get("working-overlay").classList.contains("hidden"), true);
    assert.equal(harness.get("button-reject").disabled, true);
    await harness.get("button-reject").click();
    assert.equal(harness.nativeMessages.filter(message => message.subject === "rejectRequest").length, 0);
    assert.equal(original.activity.operation.kind, "approveRequest");
    const replacement = pendingRequest(original.request.id, 2);
    harness.setState(replacement, messageState(replacement, {title: "Next request"}));
    await harness.show([replacement]);
    await harness.controller.reject();
    assert.equal(harness.nativeMessages.filter(message => message.subject === "rejectRequest").length, 1);
    const current = harness.controller;
    const snapshot = harness.visibleSnapshot();
    gate.resolve(commandReply(transactionState(original.request)));
    await approving;
    assert.equal(harness.controller, current);
    assert.deepEqual(harness.visibleSnapshot(), snapshot);
});

test("clicks during a pending fee update are discarded and failure never approves", async () => {
    for (const success of [true, false]) {
        const harness = await reviewedPopup(transactionState);
        const controller = harness.controller;
        const gate = deferred();
        harness.handlers.native = (message, fallback) => message.subject === "setTransactionSpeed" ? gate.promise : fallback(message);
        harness.get("tx-slider").emit("pointerdown");
        harness.get("tx-slider").value = "155";
        harness.get("tx-slider").emit("pointerup");
        assert.equal(harness.get("button-approve").disabled, true);
        await harness.get("button-approve").click();
        await harness.get("button-approve").click();
        await controller.approve({});
        if (success) { gate.resolve(commandReply(transactionState(controller.request, {reviewToken: requestToken(102)}))); }
        else { gate.reject(new Error("Native unavailable")); }
        await flushPopup();
        assert.deepEqual(harness.workerMessages, []);
        if (success) {
            assert.equal(harness.get("button-approve").disabled, false);
            await harness.get("button-approve").click();
            assert.equal(harness.workerMessages.length, 1);
            assert.equal(harness.workerMessages[0].reviewToken, requestToken(102));
        } else {
            assert.equal((controller.presentationActivity.kind === "failed"), true);
            await controller.approve({});
            assert.deepEqual(harness.workerMessages, []);
        }
    }
});

test("idle connection text uses only the canonical decoded provider snapshot", async () => {
    const harness = popupHarness({worker: (message, fallback) => message.subject === "getLatestConfiguration" ? {
        kind: "configuration",
        state: {
            revisions: {ethereum: 1, solana: 2},
            ethereum: {address: "0x0000000000000000000000000000000000000001", chainId: "0x1"},
            solana: {publicKey: "11111111111111111111111111111111"},
        },
    } : fallback(message)});
    await harness.boot();
    assert.equal(harness.get("idle-connection").textContent,
        "0x0000000000000000000000000000000000000001\n11111111111111111111111111111111");
});

test("idle connection text ignores a chain-only Ethereum configuration", async () => {
    const publicKey = "11111111111111111111111111111111";
    for (const solana of [null, {publicKey}]) {
        const harness = popupHarness({worker: (message, fallback) => message.subject === "getLatestConfiguration" ? {
            kind: "configuration",
            state: {
                revisions: {ethereum: 1, solana: solana ? 1 : 0},
                ethereum: {address: "", chainId: "0x2"},
                solana,
            },
        } : fallback(message)});
        await harness.boot();
        assert.equal(harness.get("idle-connection").textContent,
            solana ? publicKey : "Not connected");
    }
});

test("a timed-out action releases its controller while late raw settlement cannot replace a retry", async () => {
    const harness = await reviewedPopup(transactionState);
    const controller = harness.controller;
    const gate = deferred();
    harness.handlers.native = (message, fallback) => message.subject === "applyTransactionEdits" ? gate.promise : fallback(message);
    harness.get("tx-editor").open = true;
    harness.get("tx-editor").emit("toggle");
    const applying = harness.get("editor-apply").click();
    const timeout = harness.timerHistory.at(-1);
    assert.equal(timeout.delay, 5000);
    await harness.fire(timeout.id);
    await applying;
    assert.equal((controller.presentationActivity.kind === "failed"), true);
    assert.equal(controller.isSubmitting, false);
    harness.setState(controller.request, transactionState(controller.request, {title: "Current retry", reviewToken: requestToken(103)}));
    await harness.get("button-approve").click();
    assert.equal((controller.presentationActivity.kind === "failed"), false);
    assert.equal(harness.get("request-title").textContent, "Current retry");
    const snapshot = harness.visibleSnapshot();
    gate.resolve(commandReply(transactionState(controller.request, {title: "Late timed-out edit", reviewToken: requestToken(999)})));
    await flushPopup();
    assert.deepEqual(harness.visibleSnapshot(), snapshot);
});

test("closing a recovered stale draft cannot approve a token whose summary is still hidden", async () => {
    const harness = await reviewedPopup(transactionState);
    const controller = harness.controller;
    harness.get("tx-editor").open = true;
    harness.get("tx-editor").emit("toggle");
    harness.get("edit-gas-price").value = "8";
    harness.get("edit-gas-price").emit("input");
    const fresh = transactionState(controller.request, {
        title: "Updated review", reviewToken: requestToken(102), feeLines: ["Network fee: 0.002 ETH"],
    });
    harness.handlers.native = (message, fallback) => message.subject === "applyTransactionEdits"
        ? commandReply(fresh, "ignored") : fallback(message);
    await harness.get("editor-apply").click();
    assert.equal(harness.get("request-title").textContent, "Updated review");
    assert.equal(harness.get("tx-fee-lines").children[0].textContent, "Network fee: 0.002 ETH");
    assert.equal(harness.get("edit-gas-price").value, "8");
    harness.get("tx-editor").open = false;
    harness.get("tx-editor").emit("toggle");
    await harness.get("button-approve").click();
    assert.equal(harness.workerMessages[0].reviewToken, requestToken(102));
});

test("modal Cancel supersedes a hung alert action only with the native reject capability", async () => {
    for (const rejectable of [true, false]) {
        const alert = {title: "Review fees", message: "", actions: [{title: "Cancel", action: "cancel"}]};
        const harness = await reviewedPopup(request => transactionState(request, {alert}, {
            actions: ["resolveApprovalAlert", ...(rejectable ? ["reject"] : [])],
        }));
        const controller = harness.controller;
        const gate = deferred();
        harness.handlers.native = (message, fallback) => {
            if (message.subject === "resolveApprovalAlert") { return gate.promise; }
            if (message.subject === "rejectRequest") {
                return commandReply({id: controller.request.id, state: "working", actions: []});
            }
            return fallback(message);
        };
        const cancel = harness.get("alert-buttons").children[0];
        const resolving = cancel.emit("click");
        await flushPopup();
        assert.equal(harness.nativeMessages[0].subject, "resolveApprovalAlert");
        assert.equal(harness.nativeMessages[0].reviewToken, requestToken(101));
        await cancel.emit("click");
        assert.equal(harness.nativeMessages.filter(message => message.subject === "rejectRequest").length, rejectable ? 1 : 0);
        if (rejectable) {
            assert.equal(Object.hasOwn(harness.nativeMessages[1], "reviewToken"), false);
            assert.equal(harness.get("alert-overlay").classList.contains("hidden"), true);
            assert.equal(harness.get("screen-request").inert, true);
            assert.equal(harness.get("working-overlay").classList.contains("hidden"), false);
        }
        gate.resolve(commandReply(transactionState(controller.request, {title: "Resolved alert", reviewToken: requestToken(102)})));
        await resolving;
        if (rejectable) { assert.equal(controller.state.state, "working"); }
        else { assert.equal(controller.state.review.title, "Resolved alert"); }
    }
});

test("a pending approval locks selection and Cancel until review resumes", async () => {
    const harness = await reviewedPopup(selectionState);
    const controller = harness.controller;
    const gate = deferred();
    harness.handlers.worker = (message, fallback) => message.subject === "approveRequestWithCurrentRevisions" ? gate.promise : fallback(message);
    const row = harness.get("accounts-list").children[0];
    const selected = normalized(controller.presentation.accounts);
    const approving = controller.approveCurrent();
    await flushPopup();
    assert.equal(row.disabled, true);
    assert.equal(harness.get("network-select").disabled, true);
    await row.emit("click");
    assert.deepEqual(normalized(controller.presentation.accounts), selected);
    assert.equal(harness.get("button-reject").disabled, true);
    await harness.get("button-reject").click();
    assert.equal(harness.nativeMessages.filter(message => message.subject === "rejectRequest").length, 0);
    gate.resolve(commandReply(harness.states.get(controller.request.requestToken) ?? messageState(controller.request)));
    await approving;
    assert.equal(controller.isSubmitting, false);
    assert.equal(harness.followUpTimerId(), null);
    assert.equal(harness.get("button-reject").disabled, false);
});

test("an alert consumes an old editor request and Retry keeps preparation polling", async () => {
    const alert = {title: "Failed to load", message: "Retry the request", actions: [
        {title: "Retry", action: "retry"}, {title: "Cancel", action: "cancel"},
    ]};
    const harness = await reviewedPopup(request => transactionState(request, {
        phase: "failed", editorRequestToken: 1, alert,
    }));
    const controller = harness.controller;
    assert.equal(harness.get("tx-editor").open, false);
    assert.equal(["editing", "dragging"].includes(controller.activity.kind), false);
    harness.handlers.native = (message, fallback) => message.subject === "resolveApprovalAlert"
        ? commandReply(transactionState(controller.request, {
            phase: "preparing", editorRequestToken: 1, reviewToken: requestToken(102),
        }, {actions: ["reject", "setTransactionSpeed"]})) : fallback(message);

    await harness.get("alert-buttons").children[0].click();

    assert.equal(controller.state.review.phase, "preparing");
    assert.equal(["editing", "dragging"].includes(controller.activity.kind), false);
    assert.equal(harness.get("screen-request").inert, false);
    harness.setState(controller.request, transactionState(controller.request, {
        editorRequestToken: 1, reviewToken: requestToken(103),
    }));
    await harness.fire(harness.followUpTimerId());
    assert.equal(controller.state.review.phase, "ready");
    assert.equal(harness.get("button-approve").disabled, false);
    assert.equal(harness.get("tx-editor").open, false);
});

test("an alert replaces a stale editor draft and ignored Cancel can refresh it", async () => {
    const harness = await reviewedPopup(transactionState);
    const controller = harness.controller;
    harness.get("tx-editor").open = true;
    harness.get("tx-editor").emit("toggle");
    const alert = {title: "Unsafe fees", message: "Review the fee", actions: [
        {title: "Edit", action: "edit"}, {title: "Cancel", action: "cancel"},
    ]};
    harness.setState(controller.request, transactionState(controller.request, {
        phase: "failed", reviewToken: requestToken(102), alert,
    }));
    harness.handlers.native = (message, fallback) =>
        message.subject === "applyTransactionEdits" || message.subject === "resolveApprovalAlert"
            ? commandReply(harness.states.get(controller.request.requestToken), "ignored") : fallback(message);

    await harness.get("editor-apply").click();

    assert.equal(["editing", "dragging"].includes(controller.activity.kind), false);
    assert.equal(harness.get("tx-editor").open, false);
    assert.equal(harness.get("alert-overlay").classList.contains("hidden"), false);
    harness.setState(controller.request, transactionState(controller.request, {reviewToken: requestToken(103)}));
    harness.clearMessages();
    await harness.get("alert-buttons").children[1].click();
    assert.deepEqual(harness.nativeMessages.map(message => message.subject), ["resolveApprovalAlert"]);
    assert.equal(harness.get("alert-overlay").classList.contains("hidden"), true);
    assert.equal(harness.get("screen-request").inert, false);
    assert.equal(controller.state.review.reviewToken, requestToken(103));
});

test("a new Edit alert request still opens exclusive advanced editing", async () => {
    const alert = {title: "Unsafe fees", message: "Edit the fee", actions: [
        {title: "Edit", action: "edit"},
    ]};
    const harness = await reviewedPopup(request => transactionState(request, {
        phase: "failed", editorRequestToken: 1, alert,
    }));
    const controller = harness.controller;
    harness.handlers.native = (message, fallback) => message.subject === "resolveApprovalAlert"
        ? commandReply(transactionState(controller.request, {
            phase: "failed", editorRequestToken: 2, reviewToken: requestToken(102),
        })) : fallback(message);

    await harness.get("alert-buttons").children[0].click();

    assert.equal(harness.get("alert-overlay").classList.contains("hidden"), true);
    assert.equal(harness.get("tx-editor").open, true);
    assert.equal(controller.activity.kind, "editing");
    assert.equal((controller.activity.draft ?? controller.activity.gesture).reviewToken, requestToken(102));
    assert.equal(harness.get("editor-apply").disabled, false);
    assert.equal(harness.get("button-approve").disabled, true);
});
