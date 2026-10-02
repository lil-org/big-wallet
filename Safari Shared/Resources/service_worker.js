// ∅ 2026 lil org

importScripts("protocol.generated.js", "bridge_wire.js");

const WIRE = BigWalletBridgeWire;
const WORKFLOW_VERSION = WIRE.WORKFLOW_VERSION;
const APPLICATION_ID = "org.lil.wallet";
const UPDATE_RECOVERY_STORAGE_KEY = "workflowUpdateRecoveryNeeded";
const TRANSPORT_TIMEOUT = 5000;
const TAB_QUERY_TIMEOUT = 1000;
const NATIVE_APPROVAL_TRANSPORT_TIMEOUT = 15 * 1000;
const NATIVE_OPERATION_TIMEOUT = 180 * 1000;
const MANUAL_SWITCH_RECOVERY_ALARM = "manualSwitchRecovery";
const IDLE_RECOVERY_INTERVAL_MINUTES = 5;
const REQUEST_MAINTENANCE_INTERVAL = 30 * 1000;
const requestMaintenanceTimes = new Map;
const toolbarClicks = new Map;
let recoveryFlight = null;
let recoveryQueued = false;

const sendNativeMessage = WIRE.createTrustedNativeMessageSender({
    sendRawNativeMessage: message => browser.runtime.sendNativeMessage(APPLICATION_ID, message),
});

function privateBrowsingUnsupportedMessage() {
    try {
        const message = browser.i18n.getMessage("private_browsing_unsupported");
        if (message) { return message; }
    } catch {}
    return "Big Wallet requests are unavailable in Private Browsing.";
}

function requestIdentity(request, context) {
    const identity = context.kind === "content" ? context.identity
        : context.kind === "popup" ? WIRE.configurationIdentityForURL(request.configurationKey) : null;
    return identity && request.host === identity.host && request.configurationKey === identity.configurationKey
        ? identity : null;
}

function nativeRequestIdentity(request) {
    return {id: request.id, configurationKey: request.configurationKey,
        requestToken: request.requestToken, workflowVersion: WORKFLOW_VERSION};
}

function nativeRequestStatus(response, id) {
    const decoded = WIRE.decodeMessage("NativeStatus", response);
    return decoded?.id === id ? decoded : undefined;
}

function pageFailure(id, provider, name, message = "Failed to communicate with Big Wallet", code = -32603) {
    return {kind: "error", id, provider, name, state: null, error: {code, message}};
}

function pageConfigurationFailure() {
    return {kind: "configurationError", error: {code: 4900, message: "Failed to communicate with Big Wallet"}};
}

function decodedNativeDelivery(response, id) {
    const delivery = WIRE.decodeMessage("NativeDelivery", response);
    if (delivery?.id === id && delivery.response.id === id) {
        return {terminal: delivery.response, state: delivery.state};
    }
    const terminal = WIRE.decodeNativeResponse(response, id);
    return terminal?.kind === "error" ? {terminal, state: null} : null;
}

function pageResponse({terminal, state}) {
    if (terminal.provider === "multiple") {
        return terminal.kind === "error" ? {kind: "configurationError", error: terminal.error}
            : {kind: "configuration", state};
    }
    const base = {id: terminal.id, provider: terminal.provider, name: terminal.name, state};
    return terminal.kind === "error" ? {...base, kind: "error", error: terminal.error}
        : {...base, kind: "result", result: terminal.result, approvalCommitted: terminal.approvalCommitted};
}

async function readNativeConfiguration(configurationKey, privateBrowsing = false) {
    const id = WIRE.genId();
    const response = await WIRE.withTimeout(sendNativeMessage({
        subject: "getLatestConfiguration", id, configurationKey, workflowVersion: WORKFLOW_VERSION,
    }, privateBrowsing), TRANSPORT_TIMEOUT);
    const decoded = WIRE.decodeMessage("NativeConfigurationReply", response);
    return decoded?.id === id ? decoded.state ?? null : null;
}

async function latestConfiguration(request, context) {
    const identity = requestIdentity(request, context);
    if (!identity) { return pageConfigurationFailure(); }
    if (context.privateBrowsing) {
        return {kind: "configurationError", error: {code: 4200, message: privateBrowsingUnsupportedMessage()}};
    }
    try {
        const state = await readNativeConfiguration(identity.configurationKey);
        return state ? {kind: "configuration", state} : pageConfigurationFailure();
    } catch { return pageConfigurationFailure(); }
}

async function handleDappRequest(request, context) {
    const identity = requestIdentity(request, context);
    const message = request.message;
    if (!identity || !["ethereum", "solana"].includes(message.provider)) { return undefined; }
    if (context.privateBrowsing) {
        return pageFailure(message.id, message.provider, message.name, privateBrowsingUnsupportedMessage(), 4200);
    }
    if (message.provider === "solana") {
        const object = Object.getOwnPropertyDescriptor(message.body, "object")?.value;
        const params = WIRE.isRecord(object) ? Object.getOwnPropertyDescriptor(object, "params")?.value : null;
        const onlyIfTrusted = WIRE.isRecord(params) ? Object.getOwnPropertyDescriptor(params, "onlyIfTrusted")?.value : undefined;
        if (onlyIfTrusted !== undefined && typeof onlyIfTrusted !== "boolean") {
            return pageFailure(message.id, message.provider, message.name, "onlyIfTrusted must be a boolean", -32602);
        }
    }
    const response = await WIRE.withTimeout(sendNativeAdmission({
        ...message, ...identity, authority: request.authority,
        admissionDeadline: request.admissionDeadline, enqueueAttempt: request.enqueueAttempt,
        favicon: identity.configurationKey.startsWith("file:") ? ""
            : typeof context.favicon === "string" && context.favicon.length <= 16 * 1024 ? context.favicon : "",
        workflowVersion: WORKFLOW_VERSION,
    }), TRANSPORT_TIMEOUT);
    if (WIRE.isNativeEnqueueAcknowledgement(response, message.id)) {
        if (response.approvalRequired) { notifyPendingRequestAvailable(); cuePopup(); }
        return response;
    }
    const delivery = decodedNativeDelivery(response, message.id);
    if (!delivery) { return undefined; }
    if (delivery.state) { void broadcastConfigurationInvalidated(identity.configurationKey); }
    return pageResponse(delivery);
}

function validContentResponseRequest(request, context) {
    return !context.privateBrowsing && context.identity?.configurationKey === request.configurationKey;
}

async function handleGetResponse(request, context) {
    if (!validContentResponseRequest(request, context)) { return undefined; }
    const now = Date.now();
    const maintain = now >= (requestMaintenanceTimes.get(request.requestToken) ?? 0);
    if (maintain) {
        requestMaintenanceTimes.delete(request.requestToken);
        requestMaintenanceTimes.set(request.requestToken, now + REQUEST_MAINTENANCE_INTERVAL);
        if (requestMaintenanceTimes.size > WIRE.WORKFLOW_POLICY.maximumRetainedRequests) {
            requestMaintenanceTimes.delete(requestMaintenanceTimes.keys().next().value);
        }
    }
    const completed = await consumeStoredResponse(request, maintain ? "interactive" : "none");
    return completed?.delivery ? pageResponse(completed.delivery) : completed?.status;
}

async function acknowledgeCompletedResponse(request) {
    const response = await WIRE.withTimeout(sendNativeMessage({
        ...nativeRequestIdentity(request), subject: "acknowledgeResponse",
    }, false), TRANSPORT_TIMEOUT);
    return WIRE.isMessage("NativeAcknowledgementReply", response) && response.id === request.id &&
        (response.acknowledged === true || response.missing === true);
}

async function pollStoredResponse(request, maintenance) {
    const response = await WIRE.withTimeout(sendNativeMessage({
        ...nativeRequestIdentity(request), subject: "pollResponse", maintenance,
    }, false), TRANSPORT_TIMEOUT);
    const reply = WIRE.decodeMessage("NativeResponsePollReply", response);
    if (reply?.id !== request.id) { return undefined; }
    if (!reply.response) { return {status: reply}; }
    if (reply.response.id !== request.id) { return undefined; }
    return {delivery: {terminal: reply.response, state: reply.state}};
}

async function acknowledgePolledResponse(request, polled) {
    if (!polled?.delivery) { return polled; }
    if (!await acknowledgeCompletedResponse(request)) { return undefined; }
    await broadcastConfigurationInvalidated(request.configurationKey);
    return polled;
}

async function consumeStoredResponse(request, maintenance = "none") {
    return acknowledgePolledResponse(request, await pollStoredResponse(request, maintenance));
}

async function applyCompletedResponse(request, context) {
    if (context.privateBrowsing || !requestIdentity(request, context)) { return undefined; }
    const completed = await consumeStoredResponse(request);
    return completed?.delivery ? {applied: true}
        : completed?.status?.missing ? completed.status : undefined;
}

async function disconnect(request, context) {
    if (!requestIdentity(request, context) || context.privateBrowsing) { return undefined; }
    const response = await WIRE.withTimeout(sendNativeMessage({
        subject: "disconnect", id: request.id, provider: request.provider,
        configurationKey: request.configurationKey, attempt: request.attempt, authority: request.authority,
        workflowVersion: WORKFLOW_VERSION,
    }, false), TRANSPORT_TIMEOUT);
    const decoded = WIRE.decodeMessage("NativeDisconnectReply", response);
    const state = decoded?.state;
    if (decoded?.id !== request.id || !state) { return pageFailure(request.id, request.provider, "revokePermissions"); }
    if (decoded.revoked === true) {
        await broadcastConfigurationInvalidated(request.configurationKey);
        return {id: request.id, provider: request.provider, name: "revokePermissions",
            kind: "result", result: null, approvalCommitted: false, state};
    }
    if (decoded.stale === true) {
        return {...pageFailure(request.id, request.provider, "revokePermissions", "Authorization changed while the request was pending", 4100), state};
    }
    return pageFailure(request.id, request.provider, "revokePermissions");
}

async function handleRPC(request, context) {
    if (context.privateBrowsing) {
        return pageFailure(request?.id, "ethereum", null);
    }
    try {
        const response = await WIRE.withTimeout(sendNativeMessage(request, false), NATIVE_OPERATION_TIMEOUT);
        if (!WIRE.isCorrelatedRPCResponse(response, request.id)) { return pageFailure(request.id, "ethereum", null); }
        const base = {id: request.id, provider: "ethereum", name: null, state: null};
        if (Object.prototype.hasOwnProperty.call(response, "error")) {
            if (Object.prototype.hasOwnProperty.call(response, "result")) { return pageFailure(request.id, "ethereum", null); }
            const raw = response.error;
            return WIRE.decodePageResponse({...base, kind: "error", error: {
                code: Number.isFinite(raw?.code) ? raw.code : -32603,
                message: typeof raw?.message === "string" ? raw.message : typeof raw === "string" ? raw : "Failed to process RPC response",
                ...(raw && typeof raw === "object" && Object.prototype.hasOwnProperty.call(raw, "data") ? {data: raw.data} : {}),
            }}, request.id) || pageFailure(request.id, "ethereum", null);
        }
        return WIRE.decodePageResponse({...base, kind: "result", result: response.result, approvalCommitted: false}, request.id)
            || pageFailure(request.id, "ethereum", null);
    } catch { return pageFailure(request.id, "ethereum", null); }
}

async function ensureRecoveryAlarm(interval) {
    if (browser.extension?.inIncognitoContext === true) { return; }
    try {
        const alarm = await WIRE.withTimeout(
            browser.alarms.get(MANUAL_SWITCH_RECOVERY_ALARM), TRANSPORT_TIMEOUT
        );
        const periodInMinutes = interval ?? ([1, IDLE_RECOVERY_INTERVAL_MINUTES].includes(alarm?.periodInMinutes)
            ? alarm.periodInMinutes : IDLE_RECOVERY_INTERVAL_MINUTES);
        if (alarm?.periodInMinutes === periodInMinutes && Number.isFinite(alarm.scheduledTime) &&
            alarm.scheduledTime <= Date.now() + periodInMinutes * 60 * 1000) { return; }
        await WIRE.withTimeout(browser.alarms.create(MANUAL_SWITCH_RECOVERY_ALARM, {
            delayInMinutes: periodInMinutes, periodInMinutes,
        }), TRANSPORT_TIMEOUT);
    } catch {}
}

function sendNativeAdmission(message) {
    void ensureRecoveryAlarm(1);
    return sendNativeMessage(message, false);
}

function validRecoveryRequest(request) {
    return WIRE.isMessage("RecoveryRequest", request) &&
        WIRE.configurationIdentityForURL(request.configurationKey)?.configurationKey === request.configurationKey;
}

function recoverRequests() {
    if (browser.extension?.inIncognitoContext === true) { return Promise.resolve(); }
    if (recoveryFlight) { recoveryQueued = true; return recoveryFlight; }
    const pending = (async () => {
        void ensureRecoveryAlarm();
        const id = WIRE.genId();
        const response = await WIRE.withTimeout(sendNativeMessage({
            subject: "getRecoveryRequests", id, workflowVersion: WORKFLOW_VERSION,
        }, false), TRANSPORT_TIMEOUT);
        if (!WIRE.isMessage("NativeRecoveryReply", response) || response.id !== id ||
            !response.requests?.every(validRecoveryRequest)) { return; }
        void ensureRecoveryAlarm(response.requests.length ? 1 : IDLE_RECOVERY_INTERVAL_MINUTES);
        if (response.requests.length === 0) { return; }
        const ready = [];
        for (const request of response.requests) {
            try {
                if (request.state !== "completed" || request.manual) {
                    const polled = await pollStoredResponse(request, request.state === "completed" ? "none" : "quiet");
                    if (!polled?.delivery) { continue; }
                    if (request.manual) {
                        await broadcastConfigurationInvalidated(request.configurationKey);
                        await acknowledgeCompletedResponse(request);
                        continue;
                    }
                }
                await broadcastConfigurationInvalidated(request.configurationKey);
                ready.push(request.id);
            } catch {}
        }
        if (ready.length) { await sendResponseReady({subject: "responseReady", ids: ready, workflowVersion: WORKFLOW_VERSION}); }
    })();
    recoveryFlight = pending;
    const clear = () => {
        if (recoveryFlight === pending) { recoveryFlight = null; }
        if (recoveryQueued) { recoveryQueued = false; void recoverRequests().catch(() => {}); }
    };
    pending.then(clear, clear);
    return pending;
}

function beginManualSwitch(identity) {
    const pending = (async () => {
        let state = await readNativeConfiguration(identity.configurationKey);
        if (!state) { return undefined; }
        const admissionDeadline = Date.now() + WIRE.WORKFLOW_POLICY.requestTTLMilliseconds;
        let completionDrainUsed = false;
        let previousID = 0;
        for (let attempt = 0; attempt < 2; attempt += 1) {
            if (Date.now() >= admissionDeadline) { return undefined; }
            const id = Math.max(WIRE.genId(), previousID + 1);
            previousID = id;
            const response = await WIRE.withTimeout(sendNativeAdmission({
                ...identity, id, name: "switchAccount", provider: "unknown", body: {},
                authority: {context: state.context, revisions: state.revisions},
                admissionDeadline, enqueueAttempt: WIRE.genPrivateToken(), workflowVersion: WORKFLOW_VERSION,
            }), NATIVE_APPROVAL_TRANSPORT_TIMEOUT);
            if (WIRE.isNativeEnqueueAcknowledgement(response, response?.id) && response.state.context === state.context &&
                (response.admissionKind === "coalesced" || response.id === id)) {
                if (!response.approvalRequired && response.admissionKind === "coalesced") {
                    if (completionDrainUsed) { return undefined; }
                    completionDrainUsed = true;
                    const completed = await consumeStoredResponse({...response, configurationKey: identity.configurationKey});
                    if (!completed?.delivery && !completed?.status?.missing) { return undefined; }
                    const refreshed = await readNativeConfiguration(identity.configurationKey);
                    if (!refreshed || refreshed.context !== state.context) { return undefined; }
                    state = refreshed;
                    continue;
                }
                if (response.approvalRequired) { notifyPendingRequestAvailable(); cuePopup(); }
                return {id: response.id, requestToken: response.requestToken,
                    approvalRequired: response.approvalRequired, state: response.state,
                    configurationKey: identity.configurationKey,
                    subject: WIRE.MANUAL_SWITCH_ACKNOWLEDGED_SUBJECT, workflowVersion: WORKFLOW_VERSION};
            }
            const delivery = decodedNativeDelivery(response, id);
            if (delivery?.state) { await broadcastConfigurationInvalidated(identity.configurationKey); }
            return delivery?.terminal;
        }
    })();
    const clear = () => {
        void recoverRequests().catch(() => {});
    };
    pending.then(clear, clear);
    return pending;
}

async function handleManualSwitchIntent(request, context) {
    const identity = requestIdentity(request, context);
    if (context.privateBrowsing || !identity) { return undefined; }
    return beginManualSwitch({...identity, favicon: identity.configurationKey.startsWith("file:") ? "" : context.favicon || ""});
}

function cuePopup() {
    if (!hasConfiguredPopup()) {
        clearBadgeWithoutPopup();
        return;
    }
    try {
        Promise.resolve(browser.action?.setBadgeText?.({text: "•"})).catch(() => {});
    } catch {}
    try { Promise.resolve(browser.action?.openPopup?.()).catch(() => {}); } catch {}
}

function notifyPendingRequestAvailable() {
    try {
        Promise.resolve(browser.runtime.sendMessage({
            subject: "pendingRequestAvailable",
            workflowVersion: WORKFLOW_VERSION,
        })).catch(() => {});
    } catch {}
}

function updateBadge(request, context) {
    if (context.privateBrowsing) { return undefined; }
    if (!hasConfiguredPopup()) { return clearBadgeWithoutPopup(); }
    try {
        return browser.action?.setBadgeText?.({
            text: request.hasPendingRequests ? "•" : "",
        });
    } catch {
        return undefined;
    }
}

function clearBadgeWithoutPopup() {
    if (hasConfiguredPopup()) { return undefined; }
    try {
        return browser.action?.setBadgeText?.({text: ""});
    } catch {
        return undefined;
    }
}

function hasConfiguredPopup() {
    try {
        const manifest = browser.runtime.getManifest?.();
        const popup = manifest?.action?.default_popup ||
            manifest?.browser_action?.default_popup;
        return typeof popup === "string" && popup.length > 0;
    } catch {
        return false;
    }
}

async function openNativeWallet(tab) {
    try {
        await WIRE.withTimeout(sendNativeMessage({
            subject: "openApp",
            id: WIRE.genId(),
            workflowVersion: WORKFLOW_VERSION,
        }, tab?.incognito === true), NATIVE_APPROVAL_TRANSPORT_TIMEOUT);
    } catch {}
}

function setToolbarFailure(tabId, failed) {
    let title = failed ? "Unable to switch accounts. Click to try again." : null;
    try {
        if (failed) { title = browser.i18n.getMessage("toolbar_switch_failed") || title; }
    } catch {}
    try {
        Promise.resolve(browser.action?.setBadgeText?.({tabId, text: failed ? "!" : null})).catch(() => {});
    } catch {}
    try { Promise.resolve(browser.action?.setTitle?.({tabId, title})).catch(() => {}); } catch {}
}

async function showManualSwitchApproval(response, configurationKey) {
    const request = {
        subject: "showApproval", id: response.id, configurationKey,
        requestToken: response.requestToken, workflowVersion: WORKFLOW_VERSION,
    };
    for (let attempt = 0; attempt < 2; attempt += 1) {
        try {
            const opened = await WIRE.withTimeout(sendNativeMessage(request, false), NATIVE_APPROVAL_TRANSPORT_TIMEOUT);
            if (WIRE.isMessage("NativeOpenReply", opened) && opened.id === response.id && opened.opened === true) {
                return true;
            }
            const status = nativeRequestStatus(opened, response.id);
            if (status?.pending) { return true; }
            if (status?.ready) {
                void recoverRequests().catch(() => {});
                return true;
            }
        } catch {}
    }
    return false;
}

async function handleToolbarClick(tab) {
    if (hasConfiguredPopup()) { return; }
    const identity = WIRE.configurationIdentityForURL(tab?.url || tab?.pendingUrl);
    if (!identity || !Number.isSafeInteger(tab?.id) || tab.id < 0 || tab.incognito === true) {
        if (Number.isSafeInteger(tab?.id) && tab.id >= 0) {
            toolbarClicks.delete(tab.id);
            setToolbarFailure(tab.id, false);
        }
        await openNativeWallet(tab);
        return;
    }
    const click = {url: tab.url || tab.pendingUrl};
    toolbarClicks.set(tab.id, click);
    const updateFailure = failed => {
        if (toolbarClicks.get(tab.id) === click) { setToolbarFailure(tab.id, failed); }
    };
    updateFailure(false);
    try {
        const response = await beginManualSwitch({
            ...identity,
            favicon: !identity.configurationKey.startsWith("file:") &&
                typeof tab.favIconUrl === "string" && tab.favIconUrl.length <= 16 * 1024 ? tab.favIconUrl : "",
        });
        const acknowledged = WIRE.isManualSwitchAcknowledgement(response, response?.id, identity.configurationKey);
        const terminal = WIRE.isManualSwitchTerminalResponse(response, response?.id);
        const succeeded = acknowledged ? !response.approvalRequired ||
            await showManualSwitchApproval(response, identity.configurationKey)
            : terminal && response.kind !== "error";
        updateFailure(!succeeded);
    } catch {
        updateFailure(true);
    } finally {
        if (toolbarClicks.get(tab.id) === click) { toolbarClicks.delete(tab.id); }
    }
}

async function boundedTabsQuery() {
    try { return await WIRE.withTimeout(browser.tabs.query({}), TAB_QUERY_TIMEOUT); } catch { return null; }
}

async function broadcastConfigurationInvalidated(configurationKey) {
    const tabs = await boundedTabsQuery();
    for (const tab of tabs || []) {
        if (tab?.incognito === true || !Number.isSafeInteger(tab?.id) ||
            WIRE.configurationIdentityForURL(tab.url)?.configurationKey !== configurationKey) { continue; }
        try { Promise.resolve(browser.tabs.sendMessage(tab.id, {
            subject: "configurationInvalidated", configurationKey, workflowVersion: WORKFLOW_VERSION,
        })).catch(() => {}); } catch {}
    }
}

async function sendResponseReady(request) {
    const tabs = await boundedTabsQuery();
    for (const tab of tabs || []) {
        if (tab?.incognito === true || !Number.isSafeInteger(tab?.id)) { continue; }
        try { Promise.resolve(browser.tabs.sendMessage(tab.id, request)).catch(() => {}); } catch {}
    }
}

function persistUpdateRecovery(details) {
    if (details?.reason !== "update") { return; }
    try {
        return browser.storage.local.set({[UPDATE_RECOVERY_STORAGE_KEY]: true});
    } catch {}
}

function clearUpdateRecovery() {
    try {
        return browser.storage.local.remove(UPDATE_RECOVERY_STORAGE_KEY);
    } catch {}
}

async function handleMessage(request, context) {
    if (request.subject === "getResponse" && request.workflowVersion === undefined) {
        if (!Number.isFinite(request.id)) { return undefined; }
        return {id: request.id, provider: "multiple", bodies: ["ethereum", "solana"].map(provider => ({
            provider, error: "Big Wallet was updated. Reload this page to continue.", errorCode: -32603,
        })), providersToDisconnect: []};
    }
    const decoded = WIRE.decodeMessage(context.kind === "content" ? "ContentToWorker" : "PopupToWorker", request);
    if (!decoded) {
        return request.subject === "rpc" && WIRE.isValidRequestId(request.id)
            ? pageFailure(request.id, "ethereum", null) : undefined;
    }
    request = decoded;
    switch (request.subject) {
    case "rpc": return handleRPC(request, context);
    case "message-to-wallet": return handleDappRequest(request, context);
    case WIRE.MANUAL_SWITCH_INTENT_SUBJECT: return handleManualSwitchIntent(request, context);
    case "getResponse": return handleGetResponse(request, context);
    case "getLatestConfiguration": return latestConfiguration(request, context);
    case "applyCompletedResponse": return applyCompletedResponse(request, context);
    case "disconnect": return disconnect(request, context);
    case "updatePendingRequestBadge": await updateBadge(request, context); return undefined;
    case "responseReady":
        if (!context.privateBrowsing && WIRE.responseReadyIds(request)) {
            await sendResponseReady(request);
            await recoverRequests();
        }
        return undefined;
    default: return undefined;
    }
}

browser.runtime.onMessage.addListener((request, sender, sendResponse) => {
    const context = WIRE.authorizeRuntimeMessage("worker", request, sender, browser.runtime);
    if (!context) { return false; }
    Promise.resolve(handleMessage(request, context)).then(sendResponse, () => sendResponse());
    return true;
});

try {
    browser.runtime.onInstalled?.addListener?.(details => {
        Promise.resolve(persistUpdateRecovery(details)).catch(() => {});
        Promise.resolve(clearBadgeWithoutPopup()).catch(() => {});
        void recoverRequests().catch(() => {});
    });
    browser.runtime.onStartup?.addListener?.(() => {
        Promise.resolve(clearUpdateRecovery()).catch(() => {});
        Promise.resolve(clearBadgeWithoutPopup()).catch(() => {});
        void recoverRequests().catch(() => {});
    });
    Promise.resolve(clearBadgeWithoutPopup()).catch(() => {});
    void recoverRequests().catch(() => {});
    browser.alarms.onAlarm.addListener(alarm => alarm?.name === MANUAL_SWITCH_RECOVERY_ALARM
        ? recoverRequests() : undefined);
    browser.tabs.onUpdated?.addListener?.((tabId, changes) => {
        if (changes.status === "loading" ||
            typeof changes.url === "string" && changes.url !== toolbarClicks.get(tabId)?.url) {
            toolbarClicks.delete(tabId);
        }
    });
    browser.tabs.onRemoved?.addListener?.(tabId => { toolbarClicks.delete(tabId); });
    browser.action?.onClicked?.addListener?.(tab => {
        Promise.resolve(handleToolbarClick(tab)).catch(() => {});
    });
} catch {}
