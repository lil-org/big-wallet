// ∅ 2026 lil org

import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import vm from "node:vm";
import { popupElement } from "./test_helpers.mjs";

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

test("uses one read channel and one action channel", () => {
    assert.match(source, /nativeChannels = \{ read: Promise\.resolve\(\), action: Promise\.resolve\(\) \}/);
    assert.doesNotMatch(source, /nativeMessageDispatcher|unsettledNativeCalls|capacityFailure/);
});

test("uses review tokens for approval and mutation actions", () => {
    assert.match(source, /approvalLifecycle\.current\?\.reviewToken/);
    assert.match(source, /message\.reviewToken = reviewToken/);
    assert.doesNotMatch(source, /approvalGeneration/);
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

test("keeps FIFO queue rendering and terminal actions", () => {
    assert.match(source, /queueTab\.index = 0/);
    assert.doesNotMatch(source, /requests\.sort\(/);
    assert.match(source, /submitCurrentDecision\("approveRequest"/);
    assert.match(source, /submitCurrentDecision\("rejectRequest"/);
});

test("keeps transaction fee editing, slider, and alert actions", () => {
    assert.match(source, /setTransactionSpeed/);
    assert.match(source, /applyTransactionEdits/);
    assert.match(source, /resolveApprovalAlert/);
    assert.match(source, /beginSliderInteraction/);
    assert.match(source, /startSliderCommand/);
    assert.doesNotMatch(source, /queueSliderEvent|responseMode = "status"/);
    const pointerStart = source.indexOf('slider.addEventListener("pointerdown"');
    const pointerEnd = source.indexOf('slider.addEventListener("input"', pointerStart);
    const pointerHandler = source.slice(pointerStart, pointerEnd);
    assert.match(pointerHandler, /beginSliderInteraction/);
    assert.doesNotMatch(pointerHandler, /startSliderCommand|setTransactionSpeed/);
    const inputEnd = source.indexOf("const endDrag", pointerEnd);
    const inputHandler = source.slice(pointerEnd, inputEnd);
    assert.match(inputHandler, /beginSliderInteraction/);
    assert.doesNotMatch(inputHandler, /startSliderCommand|setTransactionSpeed/);
});

test("communication failures expose manual refresh", () => {
    assert.match(source, /state: "error"/);
    assert.match(source, /idle-check-status/);
    assert.match(source, /await fetchAndRenderState\(queueTab\.items\[queueTab\.index\]\)/);
    assert.doesNotMatch(source, /APPROVAL_STATE_RETRY|retryTimer|retryAttempts/);
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

test("tokenless compact errors are exact, refresh-only, and never polled", () => {
    const context = {
        isRecord: value => value !== null && typeof value === "object" &&
            !Array.isArray(value),
        isValidRequestId: Number.isSafeInteger,
        isRequestToken: () => false,
    };
    vm.createContext(context);
    context.isCompactApprovalErrorState = vm.runInContext(
        `(${extractedFunction("isCompactApprovalErrorState")})`,
        context
    );
    context.shouldPollApprovalState = vm.runInContext(
        `(${extractedFunction("shouldPollApprovalState")})`,
        context
    );
    context.isCompactRejectableApprovalState = () => false;
    context.canRejectApprovalState = vm.runInContext(
        `(${extractedFunction("canRejectApprovalState")})`,
        context
    );
    const error = {id: 7, state: "error", host: "wallet.example", error: "Failed"};
    assert.equal(context.isCompactApprovalErrorState(error), true);
    assert.equal(context.isCompactApprovalErrorState({...error, canReject: true}), false);
    assert.equal(context.shouldPollApprovalState(error), false);
    assert.equal(context.canRejectApprovalState(error), false);
});

test("compact rejectable approval states are tokenless, exact, and reject-only", () => {
    const context = {
        APPROVAL_KINDS: new Set,
        hasValidOptionalApprovalFields: () => true,
        isApprovalStateEnvelope: state => state?.id === 7,
        isRecord: value => value !== null && typeof value === "object" &&
            !Array.isArray(value),
        isRequestToken: () => false,
        isValidRequestId: Number.isSafeInteger,
    };
    vm.createContext(context);
    context.isCompactApprovalErrorState = vm.runInContext(
        `(${extractedFunction("isCompactApprovalErrorState")})`,
        context
    );
    context.isCompactRejectableApprovalState = vm.runInContext(
        `(${extractedFunction("isCompactRejectableApprovalState")})`,
        context
    );
    context.isRenderableApprovalState = vm.runInContext(
        `(${extractedFunction("isRenderableApprovalState")})`,
        context
    );
    context.canRejectApprovalState = vm.runInContext(
        `(${extractedFunction("canRejectApprovalState")})`,
        context
    );
    context.shouldPollApprovalState = vm.runInContext(
        `(${extractedFunction("shouldPollApprovalState")})`,
        context
    );
    const state = {
        id: 7,
        state: "working",
        host: "wallet.example",
        error: "Too much data to display",
        canReject: true,
    };

    assert.equal(context.isCompactRejectableApprovalState(state), true);
    assert.equal(context.isRenderableApprovalState(state, {id: 7}), true);
    assert.equal(context.canRejectApprovalState(state), true);
    assert.equal(context.shouldPollApprovalState(state), false);
    assert.equal(context.shouldPollApprovalState({state: "working"}), true);
    assert.equal(context.shouldPollApprovalState({state: "authenticating"}), true);
    for (const invalid of [
        {...state, reviewToken: "00000000-0000-4000-8000-000000000002"},
        {...state, canReject: false},
        {...state, state: "review"},
        {...state, extra: true},
    ]) {
        assert.equal(context.isCompactRejectableApprovalState(invalid), false);
    }

    const approve = {disabled: false};
    context.document = {getElementById: () => approve};
    context.updateApproveEnabled = vm.runInContext(
        `(${extractedFunction("updateApproveEnabled")})`,
        context
    );
    context.updateApproveEnabled(state);
    assert.equal(approve.disabled, true);
});

test("approval polling adopts an error and stops", async () => {
    const request = {id: 7, requestToken: "request"};
    const error = {id: 7, state: "error", error: "Failed"};
    const callbacks = [];
    let adopted = null;
    let overlayHidden = false;
    const context = {
        APPROVAL_POLL_INTERVAL: 1,
        NATIVE_MESSAGE_CANCELLED: Symbol("cancelled"),
        approvalLifecycle: {current: {state: "working"}, generation: 1, pollTimer: null},
        requestFor: () => request,
        isCurrentRequest: () => true,
        stopTimers: () => {},
        setTimeout: callback => { callbacks.push(callback); return 1; },
        approvalState: async () => error,
        isRenderableApprovalState: () => true,
        handleMissingState: () => false,
        hide: id => { if (id === "working-overlay") { overlayHidden = true; } },
        adoptState: state => { adopted = state; },
        acceptRenderableApprovalState: () => assert.fail("error must not enter review handling"),
        canRejectApprovalState: () => assert.fail("error must not become rejectable"),
    };
    vm.createContext(context);
    context.pollApproval = vm.runInContext(
        `(${extractedFunction("pollApproval")})`,
        context
    );

    context.pollApproval(request);
    assert.equal(callbacks.length, 1);
    await callbacks[0]();
    assert.equal(adopted, error);
    assert.equal(overlayHidden, true);
    assert.equal(callbacks.length, 1);
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

test("stranded update refreshes approvals before showing the idle cue", async () => {
    const hidden = new Map;
    const texts = new Map;
    const switchButton = {disabled: false};
    const tab = {
        configurationKey: "https://wallet.example",
        host: "wallet.example",
        id: 7,
        incognito: false,
        url: "https://wallet.example/dapp",
    };
    let flagReads = 0;
    let probes = 0;
    let queueRefreshes = 0;
    const context = {
        IS_DESKTOP_POPUP: true,
        approvalLifecycle: {current: {}},
        currentActiveTab: async () => tab,
        currentPrivateBrowsing: () => false,
        document: {getElementById: id => id === "idle-switch-account"
            ? switchButton
            : {classList: {contains: () => true}}},
        hide() {},
        localized: (_, fallback) => fallback,
        queueTab: {
            activeTab: null,
            booting: true,
            contentScriptUnavailableTab: null,
            items: [],
            snapshotStatus: "unknown",
            updateRecoveryTab: null,
        },
        readUpdateRecoveryFlag: async () => {
            flagReads += 1;
            return true;
        },
        readLatestConfiguration: () => assert.fail("recovery must not read configuration"),
        refreshQueue: async () => {
            queueRefreshes += 1;
            context.queueTab.items = [{id: 1}];
            context.queueTab.snapshotStatus = "nonempty";
        },
        sameTab: () => false,
        schedulePendingQueueRefresh() {},
        selectionRender: {idleGeneration: 0},
        setHidden: (id, value) => hidden.set(id, value),
        setText: (id, value) => texts.set(id, value),
        show() {},
        updateRecoveryTabFor: async () => {
            probes += 1;
            return tab;
        },
    };
    vm.createContext(context);
    context.canBeginIdleSwitch = vm.runInContext(
        `(${extractedFunction("canBeginIdleSwitch")})`, context
    );
    context.shouldShowUpdateRecovery = vm.runInContext(
        `(${extractedFunction("shouldShowUpdateRecovery")})`, context
    );
    context.renderIdleSwitchControls = vm.runInContext(
        `(${extractedFunction("renderIdleSwitchControls")})`, context
    );
    context.showIdle = vm.runInContext(
        `(${extractedFunction("showIdle")})`, context
    );
    const boot = vm.runInContext(`(${extractedFunction("boot")})`, context);

    await boot();
    assert.equal(context.queueTab.booting, false);
    assert.equal(context.queueTab.updateRecoveryTab, tab);
    assert.equal(flagReads, 1);
    assert.equal(probes, 1);
    assert.equal(queueRefreshes, 1);
    assert.equal(context.queueTab.snapshotStatus, "nonempty");
    assert.equal(texts.has("idle-connection"), false);

    context.queueTab.items = [];
    context.queueTab.snapshotStatus = "empty";
    await context.showIdle();
    assert.equal(texts.get("idle-connection"), "Failed to load");
    assert.equal(hidden.get("idle-check-status"), false);
    assert.equal(hidden.get("idle-switch-account"), true);
    assert.equal(switchButton.disabled, true);
});

test("update recovery keeps the popup open after the queue drains", async () => {
    let closes = 0;
    const context = {
        queueTab: {
            refreshInFlight: null,
            refreshRequested: false,
            refreshTimer: null,
            snapshotStatus: "empty",
        },
        refreshQueue: async () => [],
        shouldShowUpdateRecovery: () => true,
        stopTimers() {},
        window: {close: () => { closes += 1; }},
    };
    vm.createContext(context);
    const closeIfNothingIsLeft = vm.runInContext(
        `(${extractedFunction("closeIfNothingIsLeft")})`, context
    );
    await closeIfNothingIsLeft();
    assert.equal(closes, 0);
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

function approvalDecisionHarness({
    actionGate = null,
    kind = "signMessage",
    onActionScheduled = null,
    refreshGate = null,
    sliderGate = null,
    sliderResult = true,
    workerResponse,
} = {}) {
    const request = {
        configurationKey: "https://wallet.example",
        host: "wallet.example",
        id: 7,
        provider: "ethereum",
        requestToken: "request",
    };
    const extensionMessages = [];
    const nativeCalls = [];
    const renderedStates = [];
    let failed = false;
    let polled = false;
    let authoritativeRefreshes = 0;
    let timerStops = 0;
    let workingOverlayVisible = false;
    const approveButton = {disabled: false};
    const context = {
        WORKFLOW_VERSION: 3,
        approvalLifecycle: {
            current: {id: 7, kind, reviewToken: "review", state: "review"},
            generation: 0,
        },
        browser: {runtime: {sendMessage(message) {
            extensionMessages.push(message);
            return Promise.resolve(workerResponse);
        }}},
        canSubmitDecision: () => true,
        discardSliderCommands: () => {},
        failClosedApprovalState: () => { failed = true; },
        fetchAndRenderState: async () => {
            authoritativeRefreshes += 1;
            if (refreshGate) { await refreshGate; }
            approveButton.disabled = false;
        },
        finishSliderDragForDecision: () => {},
        hasExactKeys: (value, keys) => value !== null &&
            typeof value === "object" &&
            Object.keys(value).length === keys.length &&
            keys.every(key => Object.hasOwn(value, key)),
        isCurrentRequest: value => value === request,
        isProviderRevisions: value => value !== null &&
            typeof value === "object" &&
            Number.isSafeInteger(value.ethereum) && value.ethereum >= 0 &&
            Number.isSafeInteger(value.solana) && value.solana >= 0,
        isCompactRejectableApprovalState: state => state?.state === "working" &&
            state.kind === undefined && state.canReject === true,
        isRecord: value => value !== null && typeof value === "object" &&
            !Array.isArray(value),
        isRequestToken: () => true,
        requestFor: value => value === request || value === request.id ? request : null,
        pollApproval: () => { polled = true; },
        document: {getElementById: () => approveButton},
        queueTab: {items: [request], index: 0},
        renderState: state => { renderedStates.push(state); },
        scheduleNativeMessage(kindValue, subject, id, payload, requestToken, options = {}) {
            return {
                result: (async () => {
                    onActionScheduled?.();
                    if (actionGate) { await actionGate; }
                    if (options.isValid && !options.isValid()) {
                        return {status: "cancelled"};
                    }
                    nativeCalls.push({
                        kind: kindValue,
                        subject,
                        id,
                        payload,
                        requestToken,
                        reviewToken: options.reviewToken,
                        approvalRequest: options.approvalRequest,
                    });
                    return {status: "response", response: {ok: true}};
                })(),
            };
        },
        settleExtensionMessage: async pending => ({
            response: await pending,
            status: "response",
        }),
        show: id => {
            if (id === "working-overlay") { workingOverlayVisible = true; }
        },
        stopTimers: () => { timerStops += 1; },
        waitForSliderCommands: async () => {
            if (sliderGate) { await sliderGate; }
            return sliderResult;
        },
    };
    vm.createContext(context);
    context.submitCurrentDecision = vm.runInContext(
        `(${extractedFunction("submitCurrentDecision")})`,
        context
    );
    return {
        context,
        approveButton,
        authoritativeRefreshes: () => authoritativeRefreshes,
        extensionMessages,
        failed: () => failed,
        nativeCalls,
        polled: () => polled,
        renderedStates,
        timerStops: () => timerStops,
        workingOverlayVisible: () => workingOverlayVisible,
    };
}

test("approve delegates revision selection to the worker proxy", async () => {
    const harness = approvalDecisionHarness();
    await harness.context.submitCurrentDecision("approveRequest", {password: "secret"});
    assert.deepEqual(harness.extensionMessages, []);
    assert.deepEqual(JSON.parse(JSON.stringify(harness.nativeCalls[0].payload)), {});
    assert.equal(harness.nativeCalls[0].requestToken, "request");
    assert.equal(
        harness.nativeCalls[0].approvalRequest,
        harness.context.queueTab.items[0]
    );
    assert.equal(harness.nativeCalls[0].reviewToken, "review");
    assert.equal(harness.failed(), false);
    assert.equal(harness.polled(), true);
});

test("terminal decisions fence stale refresh and poll after their native reply", async () => {
    for (const subject of ["approveRequest", "rejectRequest"]) {
        let releaseAction;
        const actionGate = new Promise(resolve => { releaseAction = resolve; });
        let markScheduled;
        const actionScheduled = new Promise(resolve => { markScheduled = resolve; });
        let resolveRefresh;
        const staleRefresh = new Promise(resolve => { resolveRefresh = resolve; });
        const harness = approvalDecisionHarness({
            actionGate,
            onActionScheduled: markScheduled,
            workerResponse: {revisions: {ethereum: 4, solana: 9}},
        });
        harness.context.approvalState = () => staleRefresh;
        harness.context.refreshTransactionState = vm.runInContext(
            `(${extractedFunction("refreshTransactionState")})`,
            harness.context
        );
        const request = harness.context.queueTab.items[0];
        const refresh = harness.context.refreshTransactionState(request);
        const submission = harness.context.submitCurrentDecision(
            subject,
            subject === "approveRequest" ? {} : undefined
        );

        await actionScheduled;
        assert.equal(harness.context.approvalLifecycle.generation, 1);
        assert.equal(harness.timerStops(), 1);
        assert.equal(harness.workingOverlayVisible(), true);
        assert.equal(harness.polled(), false);

        resolveRefresh({
            id: request.id,
            kind: "signMessage",
            reviewToken: "stale-review",
            state: "review",
        });
        await refresh;
        assert.deepEqual(harness.renderedStates, []);
        assert.equal(harness.context.approvalLifecycle.current.reviewToken, "review");
        assert.equal(harness.polled(), false);

        releaseAction();
        await submission;
        assert.equal(harness.nativeCalls[0].subject, subject);
        assert.equal(harness.polled(), true);
    }
});

test("approval stops when the review token rotates while queued", async () => {
    let releaseAction;
    const actionGate = new Promise(resolve => { releaseAction = resolve; });
    let markScheduled;
    const actionScheduled = new Promise(resolve => { markScheduled = resolve; });
    const harness = approvalDecisionHarness({
        actionGate,
        onActionScheduled: markScheduled,
        workerResponse: {revisions: {ethereum: 4, solana: 9}},
    });
    const submission = harness.context.submitCurrentDecision("approveRequest", {});
    await actionScheduled;
    harness.context.approvalLifecycle.current = {
        ...harness.context.approvalLifecycle.current,
        reviewToken: "rotated-review",
    };
    releaseAction();
    await submission;

    assert.equal(harness.nativeCalls.length, 0);
    assert.equal(harness.failed(), false);
    assert.equal(harness.polled(), false);
    assert.equal(harness.renderedStates.at(-1).reviewToken, "rotated-review");
});

test("approval uses state recaptured after slider settlement", async () => {
    let releaseSlider;
    const sliderGate = new Promise(resolve => { releaseSlider = resolve; });
    const harness = approvalDecisionHarness({sliderGate});
    const submission = harness.context.submitCurrentDecision("approveRequest", {
        revisions: {ethereum: 99, solana: 99},
    });
    harness.context.approvalLifecycle.current = {
        kind: "addChain",
        reviewToken: "updated-review",
        state: "review",
    };
    releaseSlider();
    await submission;

    assert.equal(harness.extensionMessages.length, 0);
    assert.deepEqual(JSON.parse(JSON.stringify(harness.nativeCalls[0].payload)), {});
    assert.equal(harness.nativeCalls[0].reviewToken, "updated-review");
});

test("failed terminal slider settlement blocks approval", async () => {
    const harness = approvalDecisionHarness({sliderResult: false});

    await harness.context.submitCurrentDecision("approveRequest", {});

    assert.equal(harness.extensionMessages.length, 0);
    assert.equal(harness.nativeCalls.length, 0);
    assert.equal(harness.polled(), false);
});

test("caller-supplied provider revisions are stripped before approval proxying", async () => {
    const harness = approvalDecisionHarness();
    await harness.context.submitCurrentDecision("approveRequest", {
        revisions: {ethereum: 99, solana: 99},
    });
    assert.deepEqual(
        JSON.parse(JSON.stringify(harness.nativeCalls[0].payload)),
        {}
    );
    assert.equal(harness.failed(), false);
});

test("add-chain approval and rejection bypass revision preflight", async () => {
    const addChain = approvalDecisionHarness({kind: "addChain"});
    await addChain.context.submitCurrentDecision("approveRequest", {
        revisions: {ethereum: 99, solana: 99},
    });
    assert.equal(addChain.extensionMessages.length, 0);
    assert.deepEqual(JSON.parse(JSON.stringify(addChain.nativeCalls[0].payload)), {});

    const rejection = approvalDecisionHarness();
    await rejection.context.submitCurrentDecision("rejectRequest");
    assert.equal(rejection.extensionMessages.length, 0);
    assert.equal(rejection.nativeCalls[0].payload, undefined);
    assert.equal(rejection.nativeCalls[0].reviewToken, undefined);
});

test("compact rejectable state submits tokenless Reject without refreshing", async () => {
    const harness = approvalDecisionHarness();
    harness.context.approvalLifecycle.current = {
        id: 7,
        state: "working",
        error: "Too much data to display",
        canReject: true,
    };
    harness.context.canRejectApprovalState = vm.runInContext(
        `(${extractedFunction("canRejectApprovalState")})`,
        harness.context
    );
    harness.context.canSubmitDecision = vm.runInContext(
        `(${extractedFunction("canSubmitDecision")})`,
        harness.context
    );

    await harness.context.submitCurrentDecision("rejectRequest");

    assert.equal(harness.nativeCalls.length, 1);
    assert.equal(harness.nativeCalls[0].subject, "rejectRequest");
    assert.equal(harness.nativeCalls[0].reviewToken, undefined);
    assert.equal(harness.extensionMessages.length, 0);
    assert.equal(harness.authoritativeRefreshes(), 0);
});

test("review rejection remains valid across review-token rotation", async () => {
    let releaseAction;
    const actionGate = new Promise(resolve => { releaseAction = resolve; });
    const harness = approvalDecisionHarness();
    harness.context.scheduleNativeMessage = (_kind, subject, _id, _payload,
        _requestToken, options = {}) => ({result: (async () => {
            await actionGate;
            assert.equal(options.isValid(), true);
            assert.equal(options.reviewToken, undefined);
            return {status: "response", response: {status: "ok", subject}};
        })()});
    const rejection = harness.context.submitCurrentDecision("rejectRequest");
    harness.context.approvalLifecycle.current.reviewToken = "review-b";
    releaseAction();
    await rejection;

    assert.equal(harness.polled(), true);
});

test("alert buttons pass the click-time review token", async () => {
    const actions = [{title: "Cancel", action: "cancel"}];
    const state = {
        alert: {title: "Review fees", message: "", actions},
        reviewToken: "review-a",
        state: "review",
    };
    let click;
    let resolveMutation;
    let mutationArguments;
    let adoptedState;
    const pendingMutation = new Promise(resolve => { resolveMutation = resolve; });
    const buttons = {
        children: [],
        set innerHTML(_value) { this.children = []; },
        appendChild(button) { this.children.push(button); },
    };
    const elements = {
        "alert-overlay": {classList: {contains: () => true}},
        "alert-buttons": buttons,
        "screen-request": {inert: false},
        "alert-box": {focus() {}},
    };
    const context = {
        approvalLifecycle: {current: state},
        selectionRender: {alertKey: null, alertReturnFocus: null},
        document: {
            activeElement: null,
            createElement() {
                return {
                    addEventListener(_name, handler) { click = handler; },
                    focus() {},
                };
            },
            getElementById: id => elements[id],
        },
        closeAlert: () => {},
        setText: () => {},
        show: () => {},
        isRequestToken: value => typeof value === "string",
        mutateState: async (...args) => {
            mutationArguments = args;
            return pendingMutation;
        },
        adoptState: state => { adoptedState = state; },
        keepFollowingTransaction: () => {},
    };
    vm.createContext(context);
    const renderAlertIfNeeded = vm.runInContext(
        `(${extractedFunction("renderAlertIfNeeded")})`,
        context
    );

    renderAlertIfNeeded(state);
    const pending = click();
    context.approvalLifecycle.current = {...state, reviewToken: "review-b"};
    resolveMutation({id: 7, state: "review"});
    await pending;

    assert.equal(mutationArguments[0], "resolveApprovalAlert");
    assert.equal(mutationArguments[3], "review-a");
    assert.equal(adoptedState, undefined);
});

test("alert mutations forward the explicit review token to native dispatch", async () => {
    const request = {id: 7, requestToken: "request"};
    let scheduledOptions;
    const context = {
        requestFor: () => request,
        isCurrentRequest: () => true,
        scheduleNativeMessage(_kind, _subject, _id, _payload, _token, options) {
            scheduledOptions = options;
            return {result: Promise.resolve({status: "response", response: {ok: true}})};
        },
    };
    vm.createContext(context);
    const requestState = vm.runInContext(
        `(${extractedFunction("requestState")})`,
        context
    );

    await requestState(
        "resolveApprovalAlert",
        {action: "cancel"},
        request,
        "mutation",
        null,
        null,
        "review-a"
    );

    assert.equal(scheduledOptions.reviewToken, "review-a");
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

function missingReconciliationHarness() {
    const request = {id: 7, requestToken: "first"};
    let refreshes = 0;
    let reconciliation;
    let settleRefresh;
    let stopped = 0;
    const requestScreen = {classList: {contains: () => false}};
    const idleScreen = {classList: {contains: () => true}};
    const context = {
        approvalLifecycle: {completion: null},
        closeAlert: () => {},
        document: {getElementById(id) {
            if (id === "screen-request") { return requestScreen; }
            if (id === "screen-idle") { return idleScreen; }
            throw new Error(`Unexpected element: ${id}`);
        }},
        isCurrentRequest: request => request === context.queueTab.items[context.queueTab.index],
        queueTab: {
            index: 0,
            items: [request],
            refreshInFlight: null,
            refreshRequested: false,
            refreshTimer: null,
            snapshotStatus: "nonempty",
        },
        refreshQueue: () => {
            refreshes += 1;
            return new Promise(resolve => { settleRefresh = resolve; });
        },
        requestFor: value => value,
        sameRequest: (left, right) => !!left && !!right &&
            left.id === right.id && left.requestToken === right.requestToken,
        shouldShowUpdateRecovery: () => false,
        stopTimers: () => { stopped += 1; },
        window: {close: () => assert.fail("nonempty queue must remain open")},
    };
    vm.createContext(context);
    context.shouldDeferQueueRefreshForCurrentRequest = vm.runInContext(
        `(${extractedFunction("shouldDeferQueueRefreshForCurrentRequest")})`,
        context
    );
    context.closeIfNothingIsLeft = vm.runInContext(
        `(${extractedFunction("closeIfNothingIsLeft")})`,
        context
    );
    const reconcileMissingRequest = vm.runInContext(
        `(${extractedFunction("reconcileMissingRequest")})`,
        context
    );
    context.reconcileMissingRequest = value => {
        const operation = reconcileMissingRequest(value);
        reconciliation ??= operation;
        return operation;
    };
    context.handleMissingState = vm.runInContext(
        `(${extractedFunction("handleMissingState")})`,
        context
    );
    return {
        context,
        reconciliation: () => reconciliation,
        refreshes: () => refreshes,
        request,
        resolveRefresh(value) { settleRefresh(value); },
        stopped: () => stopped,
    };
}

test("missing approval state reconciles through the authoritative queue once", async () => {
    const harness = missingReconciliationHarness();
    assert.equal(harness.context.shouldDeferQueueRefreshForCurrentRequest(), true);

    assert.equal(
        harness.context.handleMissingState({state: "missing"}, harness.request),
        true
    );
    assert.equal(harness.context.approvalLifecycle.completion, harness.request);
    assert.equal(harness.context.shouldDeferQueueRefreshForCurrentRequest(), false);
    assert.equal(harness.refreshes(), 1);
    assert.equal(harness.stopped(), 2);

    assert.equal(
        harness.context.handleMissingState({state: "missing"}, harness.request),
        true
    );
    assert.equal(harness.refreshes(), 1);
    harness.resolveRefresh([harness.request]);
    await harness.reconciliation();
    assert.equal(harness.context.approvalLifecycle.completion, null);
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
        stopTimers() {},
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

test("approval uses the long timeout and holds its action channel until reply", async () => {
    const calls = [];
    const nativeOperationFlags = [];
    let resolveApproval;
    const pendingApproval = new Promise(resolve => { resolveApproval = resolve; });
    const context = {
        approvalLifecycle: {current: {reviewToken: "review"}},
        nativeChannels: {read: Promise.resolve(), action: Promise.resolve()},
        nativeMessage(subject) {
            calls.push(subject);
            return subject === "approveRequest"
                ? pendingApproval
                : Promise.resolve(`${subject}-response`);
        },
        settleNativeMessage(pending, nativeOperation) {
            nativeOperationFlags.push(nativeOperation);
            return nativeOperation
                ? pending
                : Promise.reject(new Error("bounded timeout"));
        },
    };
    vm.createContext(context);
    const scheduleNativeMessage = vm.runInContext(
        `(${extractedFunction("scheduleNativeMessage")})`,
        context
    );

    const approval = scheduleNativeMessage("action", "approveRequest", 1);
    for (let index = 0; index < 5 && calls.length === 0; index += 1) {
        await Promise.resolve();
    }
    const rejection = scheduleNativeMessage("action", "rejectRequest", 2);
    await Promise.resolve();
    assert.deepEqual(calls, ["approveRequest"]);
    assert.deepEqual(nativeOperationFlags, [true]);

    resolveApproval("approved");
    assert.equal((await approval.result).response, "approved");
    assert.equal((await rejection.result).status, "failure");
    assert.deepEqual(calls, ["approveRequest", "rejectRequest"]);
    assert.deepEqual(nativeOperationFlags, [true, false]);
});

test("timed-out actions release their channel before raw settlement", async () => {
    const calls = [];
    let resolveFirst;
    const firstRaw = new Promise(resolve => { resolveFirst = resolve; });
    const context = {
        approvalLifecycle: {current: {reviewToken: "review"}},
        nativeChannels: {read: Promise.resolve(), action: Promise.resolve()},
        nativeMessage(subject) {
            calls.push(subject);
            return subject === "first"
                ? firstRaw
                : Promise.resolve(`${subject}-response`);
        },
        settleNativeMessage(pending) {
            return calls.at(-1) === "first"
                ? Promise.reject(new Error("bounded timeout"))
                : pending;
        },
    };
    vm.createContext(context);
    const scheduleNativeMessage = vm.runInContext(
        `(${extractedFunction("scheduleNativeMessage")})`,
        context
    );

    const first = scheduleNativeMessage("mutation", "first", 1);
    assert.equal((await first.result).status, "failure");
    const second = scheduleNativeMessage("mutation", "second", 2);
    assert.equal((await second.result).response, "second-response");
    assert.deepEqual(calls, ["first", "second"]);
    resolveFirst("late-first-response");
    await Promise.resolve();
    assert.deepEqual(calls, ["first", "second"]);
});

test("queued actions capture the current review token at dispatch", async () => {
    let releasePredecessor;
    const predecessor = new Promise(resolve => { releasePredecessor = resolve; });
    const observedTokens = [];
    const context = {
        approvalLifecycle: {current: {reviewToken: "old-token"}},
        nativeChannels: {read: Promise.resolve(), action: predecessor},
        nativeMessage(_subject, _id, _payload, _requestToken, reviewToken) {
            observedTokens.push(reviewToken);
            return Promise.resolve("ok");
        },
        settleNativeMessage: pending => pending,
    };
    vm.createContext(context);
    const scheduleNativeMessage = vm.runInContext(
        `(${extractedFunction("scheduleNativeMessage")})`,
        context
    );
    const action = scheduleNativeMessage("action", "approveRequest", 1);
    context.approvalLifecycle.current.reviewToken = "new-token";
    releasePredecessor();
    assert.equal((await action.result).response, "ok");
    assert.deepEqual(observedTokens, ["new-token"]);
});

test("queued actions honor an explicit review token at dispatch", async () => {
    let releasePredecessor;
    const predecessor = new Promise(resolve => { releasePredecessor = resolve; });
    const observedTokens = [];
    const context = {
        approvalLifecycle: {current: {reviewToken: "old-token"}},
        nativeChannels: {read: Promise.resolve(), action: predecessor},
        nativeMessage(_subject, _id, _payload, _requestToken, reviewToken) {
            observedTokens.push(reviewToken);
            return Promise.resolve("ok");
        },
        settleNativeMessage: pending => pending,
    };
    vm.createContext(context);
    const scheduleNativeMessage = vm.runInContext(
        `(${extractedFunction("scheduleNativeMessage")})`,
        context
    );
    const action = scheduleNativeMessage(
        "action",
        "approveRequest",
        1,
        undefined,
        undefined,
        {reviewToken: "reviewed-token"}
    );
    context.approvalLifecycle.current.reviewToken = "new-token";
    releasePredecessor();
    assert.equal((await action.result).response, "ok");
    assert.deepEqual(observedTokens, ["reviewed-token"]);
});

test("tokenless actions suppress the dynamic review token at dispatch", async () => {
    const observedTokens = [];
    const context = {
        approvalLifecycle: {current: {reviewToken: "current-token"}},
        nativeChannels: {read: Promise.resolve(), action: Promise.resolve()},
        nativeMessage(_subject, _id, _payload, _requestToken, reviewToken) {
            observedTokens.push(reviewToken);
            return Promise.resolve("ok");
        },
        settleNativeMessage: pending => pending,
    };
    vm.createContext(context);
    const scheduleNativeMessage = vm.runInContext(
        `(${extractedFunction("scheduleNativeMessage")})`,
        context
    );

    const action = scheduleNativeMessage(
        "action",
        "rejectRequest",
        1,
        undefined,
        "request-token",
        {reviewToken: undefined}
    );

    assert.equal((await action.result).response, "ok");
    assert.deepEqual(observedTokens, [undefined]);
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
        admissionDeadline: Date.now() + 60_000,
        configurationKey: "https://wallet.example",
        id: 41,
        subject: "manualSwitchInFlight",
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

test("manual Switch Account accepts every exact owner response class", async () => {
    const responses = [
        {
            admissionDeadline: Date.now() + 60_000,
            configurationKey: "https://wallet.example",
            id: 41,
            subject: "manualSwitchInFlight",
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
            configurationKey: "https://other.example",
            id: 41,
            subject: "manualSwitchInFlight",
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
        admissionDeadline: Date.now() + 60_000,
        configurationKey: "https://wallet.example",
        id: 41,
        subject: "manualSwitchInFlight",
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

test("error-screen Refresh fetches the visible request directly", async () => {
    const request = {id: 7};
    let fetched = null;
    const context = {
        approvalLifecycle: {current: {id: 7, state: "error"}},
        queueTab: {items: [request], index: 0},
        document: {getElementById: () => ({disabled: false})},
        show: () => {},
        fetchAndRenderState: async value => { fetched = value; },
        refreshQueue: () => assert.fail("error refresh must not enter queue deferral"),
    };
    vm.createContext(context);
    const approveCurrent = vm.runInContext(
        `(${extractedFunction("approveCurrent")})`,
        context
    );
    await approveCurrent();
    assert.equal(fetched, request);
});

test("terminal slider mutation adopts the rotated review state", async () => {
    const request = { id: 9, requestToken: "request" };
    let mutationArguments;
    let adoptedState;
    const context = {
        approvalLifecycle: { current: { reviewToken: "old" } },
        transactionInteraction: { generation: 1 },
        requestFor: value => value,
        isCurrentRequest: () => true,
        mutateState: async (...args) => {
            mutationArguments = args;
            return {
                id: 9,
                state: "review",
                reviewToken: "00000000-0000-0000-0000-000000000001",
            };
        },
        isRequestToken: value => typeof value === "string" && value.length > 0,
        fetchAndRenderState: () => assert.fail("current token must not refresh"),
        adoptState: state => { adoptedState = state; },
        keepFollowingTransaction: () => {},
    };
    vm.createContext(context);
    const sendSliderEvent = vm.runInContext(
        `(${extractedFunction("sendSliderEvent")})`,
        context
    );

    assert.equal(await sendSliderEvent("ended", 10, request, 1, "old"), true);
    assert.equal(
        adoptedState.reviewToken,
        "00000000-0000-0000-0000-000000000001"
    );
    assert.equal(mutationArguments[3], "old");
});

test("stale terminal slider tokens refresh without applying a fee", async () => {
    const request = {id: 9, requestToken: "request"};
    let refreshes = 0;
    const context = {
        approvalLifecycle: {current: {reviewToken: "review-b"}},
        transactionInteraction: {generation: 1},
        requestFor: value => value,
        isCurrentRequest: () => true,
        isRequestToken: value => typeof value === "string",
        mutateState: () => assert.fail("stale terminal command must stay local"),
        fetchAndRenderState: async value => {
            assert.equal(value, request);
            refreshes += 1;
        },
    };
    vm.createContext(context);
    const sendSliderEvent = vm.runInContext(
        `(${extractedFunction("sendSliderEvent")})`,
        context
    );

    assert.equal(
        await sendSliderEvent("ended", 140, request, 1, "review-a"),
        false
    );
    assert.equal(refreshes, 1);
});

test("ignored terminal slider mutations refresh and resolve false", async () => {
    const request = {id: 9, requestToken: "request"};
    let refreshes = 0;
    const context = {
        approvalLifecycle: {current: {reviewToken: "review-a"}},
        transactionInteraction: {generation: 1},
        requestFor: value => value,
        isCurrentRequest: () => true,
        isRequestToken: value => typeof value === "string",
        mutateState: async () => null,
        fetchAndRenderState: async () => { refreshes += 1; },
    };
    vm.createContext(context);
    const sendSliderEvent = vm.runInContext(
        `(${extractedFunction("sendSliderEvent")})`,
        context
    );

    assert.equal(
        await sendSliderEvent("ended", 140, request, 1, "review-a"),
        false
    );
    assert.equal(refreshes, 1);
});

test("transaction refresh defers rendering while a slider command is active", async () => {
    const request = {id: 9, requestToken: "request"};
    const state = {
        id: 9,
        kind: "sendTransaction",
        state: "review",
        slider: {visible: true, position: 175},
    };
    for (const lastStateJSON of ["different", JSON.stringify(state)]) {
        let renders = 0;
        let sliderWrites = 0;
        const slider = {set value(_value) { sliderWrites += 1; }};
        const context = {
            NATIVE_MESSAGE_CANCELLED: Symbol("cancelled"),
            approvalLifecycle: {
                current: {id: 9, kind: "sendTransaction", state: "review"},
                generation: 1,
            },
            selectionRender: {lastStateJSON},
            transactionInteraction: {
                activeCommand: {},
                sliderDragging: false,
            },
            requestFor: () => request,
            isCurrentRequest: () => true,
            approvalState: async () => state,
            isRenderableApprovalState: () => true,
            failClosedApprovalState: () => assert.fail("state is renderable"),
            handleMissingState: () => false,
            renderState: () => { renders += 1; },
            document: {getElementById: () => slider},
            updateTransactionRefreshBackoff: () => {},
            shouldPollApprovalState: () => false,
            pollApproval: () => assert.fail("review state must not poll"),
            scheduleTransactionRefresh: () => {},
        };
        vm.createContext(context);
        const refreshTransactionState = vm.runInContext(
            `(${extractedFunction("refreshTransactionState")})`,
            context
        );

        await refreshTransactionState(request);

        assert.equal(renders, 0);
        assert.equal(sliderWrites, 0);
        assert.equal(context.approvalLifecycle.current, state);
    }
});

test("keyboard slider inputs stay local and send one terminal mutation", async () => {
    const request = {id: 9, requestToken: "request"};
    const slider = {disabled: false, value: "100"};
    const calls = [];
    let releaseTerminal;
    const terminalGate = new Promise(resolve => { releaseTerminal = resolve; });
    const context = {
        approvalLifecycle: {current: {reviewToken: "review-a"}},
        transactionInteraction: {
            activeCommand: null,
            generation: 1,
            ignoreSliderUntilRelease: false,
            sliderDragging: false,
            sliderRequest: null,
            sliderReviewToken: null,
        },
        requestFor: value => value,
        isCurrentRequest: value => value === request,
        sameRequest: (left, right) => left === right,
        isRequestToken: value => typeof value === "string",
        document: {getElementById: () => slider},
        async sendSliderEvent(...arguments_) {
            calls.push(arguments_);
            await terminalGate;
            return true;
        },
    };
    vm.createContext(context);
    context.finishSliderCommand = vm.runInContext(
        `(${extractedFunction("finishSliderCommand")})`,
        context
    );
    context.beginSliderInteraction = vm.runInContext(
        `(${extractedFunction("beginSliderInteraction")})`,
        context
    );
    context.startSliderCommand = vm.runInContext(
        `(${extractedFunction("startSliderCommand")})`,
        context
    );
    context.finishSliderInteraction = vm.runInContext(
        `(${extractedFunction("finishSliderInteraction")})`,
        context
    );

    assert.equal(context.beginSliderInteraction(request), true);
    slider.value = "120";
    slider.value = "145";
    assert.equal(calls.length, 0);
    const completion = context.finishSliderInteraction("ended");
    assert.equal(calls.length, 1);
    assert.deepEqual(calls[0].slice(0, 3), ["ended", 145, request]);
    assert.equal(context.beginSliderInteraction(request), false);
    assert.equal(slider.disabled, true);

    releaseTerminal();
    assert.equal(await completion, true);
    assert.equal(context.transactionInteraction.activeCommand, null);
});

test("slider mutation validity is fenced to its queued review token", async () => {
    const request = {id: 9, requestToken: "request"};
    let releaseRequest;
    const requestGate = new Promise(resolve => { releaseRequest = resolve; });
    let remainsValid;
    const cancelled = Symbol("cancelled");
    const context = {
        NATIVE_MESSAGE_CANCELLED: cancelled,
        approvalLifecycle: {
            current: {reviewToken: "review-a"},
            generation: 0,
            mutation: null,
        },
        transactionInteraction: {activeCommand: null},
        requestFor: value => value,
        isCurrentRequest: () => true,
        sameRequest: (left, right) => left === right,
        waitForSliderCommands: async () => true,
        resetTransactionRefreshBackoff: () => {},
        async requestState(_subject, _payload, _request, _kind, _owner, validity) {
            remainsValid = validity;
            await requestGate;
            return validity() ? {id: 9, state: "review"} : cancelled;
        },
        isRenderableApprovalState: () => true,
        isApprovalStateEnvelope: () => true,
        isRecord: value => value !== null && typeof value === "object",
        failClosedApprovalState: () => assert.fail("stale token must cancel"),
        handleMissingState: () => false,
    };
    vm.createContext(context);
    const mutateState = vm.runInContext(
        `(${extractedFunction("mutateState")})`,
        context
    );

    const pending = mutateState(
        "setTransactionSpeed",
        {interaction: "ended", value: 140},
        request,
        "review-a"
    );
    for (let attempt = 0; attempt < 5 && !remainsValid; attempt += 1) {
        await Promise.resolve();
    }
    assert.equal(remainsValid(), true);
    context.approvalLifecycle.current.reviewToken = "review-b";
    assert.equal(remainsValid(), false);
    releaseRequest();
    assert.equal(await pending, null);
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

test("full popup boot renders a queued review request", async () => {
    const elements = new Map;
    const documentListeners = new Map;
    const nativeSubjects = [];
    const requestToken = "00000000-0000-0000-0000-000000000001";
    const reviewToken = "00000000-0000-0000-0000-000000000002";
    const documentElement = popupElement("document-element");
    const document = {
        documentElement,
        addEventListener(name, listener) { documentListeners.set(name, listener); },
        createElement: () => popupElement("created"),
        getElementById(id) {
            if (!elements.has(id)) { elements.set(id, popupElement(id)); }
            return elements.get(id);
        },
        querySelectorAll: () => [],
    };
    const pendingRequest = {
        configurationKey: "https://wallet.example",
        host: "wallet.example",
        id: 7,
        provider: "ethereum",
        receivedAt: Date.now(),
        requestToken,
        revisions: {ethereum: 0, solana: 0},
        sequence: 0,
    };
    const browser = {
        extension: {inIncognitoContext: false},
        runtime: {
            getManifest: () => ({version: "1.0.99"}),
            onMessage: {addListener() {}},
            sendMessage: async () => undefined,
            async sendNativeMessage(_application, message) {
                nativeSubjects.push(message.subject);
                if (message.subject === "getPendingRequests") {
                    return {completedResponses: [], requests: [pendingRequest]};
                }
                if (message.subject === "getApprovalState") {
                    return {
                        account: {name: "Primary", croppedAddress: "0x1234"},
                        host: "wallet.example",
                        id: 7,
                        kind: "signMessage",
                        meta: "Hello from the dapp",
                        reviewToken,
                        state: "review",
                        title: "Sign message",
                    };
                }
                throw new Error(`Unexpected native subject: ${message.subject}`);
            },
        },
        tabs: {
            query: async () => [{
                id: 3,
                incognito: false,
                url: "https://wallet.example/path",
            }],
        },
    };
    const isRecord = value => value !== null && typeof value === "object" &&
        !Array.isArray(value);
    const BigWalletBridgeWire = {
        BUILD_VERSION: packagedBuildVersion,
        MANUAL_SWITCH_INTENT_SUBJECT: "manualSwitchIntent",
        MAX_RESPONSE_READY_IDS: 16,
        WORKFLOW_POLICY: {
            maximumNativeChainIdHex: "7fffffffffffffff",
            maximumRetainedRequests: 16,
            selectionAccountCoins: ["ethereum", "solana"],
            solanaClusterValues: ["mainnetBeta", "devnet", "testnet"],
        },
        WORKFLOW_VERSION: 3,
        configurationIdentityForURL: () => ({
            configurationKey: "https://wallet.example",
            host: "wallet.example",
            legacyConfigurationKey: "wallet.example",
        }),
        createTrustedNativeMessageSender: ({sendRawNativeMessage}) => message =>
            sendRawNativeMessage(message),
        genId: (() => { let id = 100; return () => ++id; })(),
        genPrivateToken: () => "00000001000000020000000300000004",
        hasExactKeys: (value, keys) => isRecord(value) &&
            Object.keys(value).length === keys.length &&
            keys.every(key => Object.hasOwn(value, key)),
        isConfiguration: value => isRecord(value) &&
            (value.provider === "ethereum" || value.provider === "solana"),
        isCanonicalEthereumChainId: value =>
            typeof value === "string" && /^0x[1-9a-f][0-9a-f]*$/.test(value),
        isManualSwitchAcknowledgement: () => false,
        isManualSwitchInFlightStatus: () => false,
        isManualSwitchTerminalResponse: () => false,
        isPendingRequestAvailable: () => false,
        isPrivateToken: value => typeof value === "string",
        isProviderRevisions: value => isRecord(value) &&
            Number.isSafeInteger(value.ethereum) &&
            Number.isSafeInteger(value.solana),
        isRecord,
        isRequestToken: value => typeof value === "string" && value.length > 0,
        isValidRequestId: Number.isSafeInteger,
        withTimeout: pending => Promise.resolve(pending),
    };
    const context = vm.createContext({
        BigWalletBridgeWire,
        browser,
        clearTimeout() {},
        console: {error() {}, log() {}},
        document,
        navigator: {maxTouchPoints: 0},
        setTimeout: () => 1,
        window: {close() {}},
    });
    new vm.Script(source, {filename: "popup.js"}).runInContext(context);
    documentListeners.get("DOMContentLoaded")();
    for (let attempt = 0; attempt < 20; attempt += 1) {
        await new Promise(resolve => setImmediate(resolve));
        if (!document.getElementById("screen-request").classList.contains("hidden")) {
            break;
        }
    }
    assert.deepEqual(nativeSubjects, ["getPendingRequests", "getApprovalState"]);
    assert.equal(
        document.getElementById("screen-request").classList.contains("hidden"),
        false
    );
    assert.equal(document.getElementById("request-title").textContent, "Sign message");
    assert.equal(
        document.getElementById("section-message").classList.contains("hidden"),
        false
    );
    assert.equal(
        document.getElementById("working-overlay").classList.contains("hidden"),
        true
    );
});
