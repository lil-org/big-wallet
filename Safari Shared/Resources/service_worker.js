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
const rpcBudget = WIRE.createRPCRequestBudget();
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

async function selectedTabIdentity(target) {
    try {
        const tab = await WIRE.withTimeout(browser.tabs.get(target.tabId), TAB_QUERY_TIMEOUT);
        const identity = WIRE.configurationIdentityForURL(tab?.url);
        return tab?.id === target.tabId && tab.incognito === false &&
            identity?.configurationKey === target.configurationKey ? identity : null;
    } catch { return null; }
}

function nativeRequestIdentity(request) {
    return {id: request.id, configurationKey: request.configurationKey,
        requestToken: request.requestToken, workflowVersion: WORKFLOW_VERSION};
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

async function readNativeConfiguration(configurationKey, nativeContext) {
    const id = WIRE.genId();
    const response = await WIRE.withTimeout(sendNativeMessage({
        subject: "getLatestConfiguration", id, configurationKey, workflowVersion: WORKFLOW_VERSION,
    }, nativeContext), TRANSPORT_TIMEOUT);
    const decoded = WIRE.decodeMessage("NativeConfigurationReply", response);
    return decoded?.id === id ? decoded.state ?? null : null;
}

async function latestConfiguration(request, nativeContext) {
    if (!nativeContext) { return pageConfigurationFailure(); }
    if (nativeContext.privateBrowsing) {
        return {kind: "configurationError", error: {code: 4200, message: privateBrowsingUnsupportedMessage()}};
    }
    const identity = nativeContext.source === "site" ? nativeContext.site
        : nativeContext.source === "popup" ? await selectedTabIdentity(request.target) : null;
    if (!identity) { return pageConfigurationFailure(); }
    try {
        const state = await readNativeConfiguration(identity.configurationKey, nativeContext);
        return state ? {kind: "configuration", state} : pageConfigurationFailure();
    } catch { return pageConfigurationFailure(); }
}

async function handleDappRequest(request, nativeContext) {
    const message = request.message;
    const identity = nativeContext?.source === "site" ? nativeContext.site : null;
    if (!identity || !["ethereum", "solana"].includes(message.provider)) {
        return pageFailure(message.id, message.provider, message.name);
    }
    if (nativeContext.privateBrowsing) {
        return pageFailure(message.id, message.provider, message.name, privateBrowsingUnsupportedMessage(), 4200);
    }
    if (message.provider === "solana") {
        const params = message.body.object.params;
        const onlyIfTrusted = WIRE.isRecord(params) ? params.onlyIfTrusted : undefined;
        if (onlyIfTrusted !== undefined && typeof onlyIfTrusted !== "boolean") {
            return pageFailure(message.id, message.provider, message.name, "onlyIfTrusted must be a boolean", -32602);
        }
    }
    const response = await WIRE.withTimeout(sendNativeAdmission({
        ...message, ...identity, authority: request.authority,
        admissionDeadline: request.admissionDeadline, enqueueAttempt: request.enqueueAttempt,
        workflowVersion: WORKFLOW_VERSION,
    }, nativeContext), TRANSPORT_TIMEOUT);
    if (WIRE.isNativeEnqueueAcknowledgement(response, message.id)) {
        if (response.approvalRequired) { notifyPendingRequestAvailable(); cuePopup(); }
        return response;
    }
    const delivery = decodedNativeDelivery(response, message.id);
    if (!delivery) { return undefined; }
    if (delivery.state) { void broadcastConfigurationInvalidated(identity.configurationKey); }
    return pageResponse(delivery);
}

async function handleGetResponse(request, nativeContext) {
    if (nativeContext?.source !== "site" || nativeContext.privateBrowsing) { return undefined; }
    request = {...request, configurationKey: nativeContext.site.configurationKey};
    const now = Date.now();
    const maintain = now >= (requestMaintenanceTimes.get(request.requestToken) ?? 0);
    if (maintain) {
        requestMaintenanceTimes.delete(request.requestToken);
        requestMaintenanceTimes.set(request.requestToken, now + REQUEST_MAINTENANCE_INTERVAL);
        if (requestMaintenanceTimes.size > WIRE.WORKFLOW_POLICY.maximumRetainedRequests) {
            requestMaintenanceTimes.delete(requestMaintenanceTimes.keys().next().value);
        }
    }
    const completed = await consumeStoredResponse(request, nativeContext, maintain ? "interactive" : "none");
    return completed?.delivery ? pageResponse(completed.delivery) : completed?.status;
}

async function acknowledgeCompletedResponse(request, nativeContext) {
    const response = await WIRE.withTimeout(sendNativeMessage({
        ...nativeRequestIdentity(request), subject: "acknowledgeResponse",
    }, nativeContext), TRANSPORT_TIMEOUT);
    return WIRE.isMessage("NativeAcknowledgementReply", response) && response.id === request.id &&
        (response.acknowledged === true || response.missing === true);
}

async function pollStoredResponse(request, nativeContext, maintenance) {
    const response = await WIRE.withTimeout(sendNativeMessage({
        ...nativeRequestIdentity(request), subject: "pollResponse", maintenance,
    }, nativeContext), TRANSPORT_TIMEOUT);
    const reply = WIRE.decodeMessage("NativeResponsePollReply", response);
    if (reply?.id !== request.id) { return undefined; }
    if (!reply.response) { return {status: reply}; }
    if (reply.response.id !== request.id) { return undefined; }
    return {delivery: {terminal: reply.response, state: reply.state}};
}

async function acknowledgePolledResponse(request, nativeContext, polled) {
    if (!polled?.delivery) { return polled; }
    if (!await acknowledgeCompletedResponse(request, nativeContext)) { return undefined; }
    await broadcastConfigurationInvalidated(request.configurationKey);
    return polled;
}

async function consumeStoredResponse(request, nativeContext, maintenance = "none") {
    return acknowledgePolledResponse(request, nativeContext, await pollStoredResponse(request, nativeContext, maintenance));
}

async function applyCompletedResponse(request, nativeContext) {
    if (nativeContext?.source !== "popup" || nativeContext.privateBrowsing ||
        WIRE.configurationIdentityForURL(request.configurationKey)?.configurationKey !== request.configurationKey) { return undefined; }
    const completed = await consumeStoredResponse(request, nativeContext);
    return completed?.delivery ? {applied: true}
        : completed?.status?.missing ? completed.status : undefined;
}

async function disconnect(request, nativeContext) {
    if (nativeContext?.source !== "site" || nativeContext.privateBrowsing) { return undefined; }
    const configurationKey = nativeContext.site.configurationKey;
    const response = await WIRE.withTimeout(sendNativeMessage({
        subject: "disconnect", id: request.id, provider: request.provider,
        configurationKey, attempt: request.attempt, authority: request.authority,
        workflowVersion: WORKFLOW_VERSION,
    }, nativeContext), TRANSPORT_TIMEOUT);
    const decoded = WIRE.decodeMessage("NativeDisconnectReply", response);
    const state = decoded?.state;
    if (decoded?.id !== request.id || !state) { return pageFailure(request.id, request.provider, "revokePermissions"); }
    if (decoded.revoked === true) {
        await broadcastConfigurationInvalidated(configurationKey);
        return {id: request.id, provider: request.provider, name: "revokePermissions",
            kind: "result", result: null, approvalCommitted: false, state};
    }
    if (decoded.stale === true) {
        return {...pageFailure(request.id, request.provider, "revokePermissions", "Authorization changed while the request was pending", 4100), state};
    }
    return pageFailure(request.id, request.provider, "revokePermissions");
}

async function handleRPC(request, nativeContext) {
    if (nativeContext?.source !== "site" || nativeContext.privateBrowsing) {
        return pageFailure(request?.id, "ethereum", null);
    }
    const bytes = WIRE.rpcRequestByteCount(request.body);
    const release = bytes === null ? null : rpcBudget.reserve(nativeContext.site.configurationKey, bytes);
    if (!release) {
        return {...pageFailure(request.id, "ethereum", null),
            error: WIRE.rpcAdmissionError(bytes === null ? "request_too_large" : "busy")};
    }
    try {
        const response = await WIRE.withTimeout(sendNativeMessage({
            subject: request.subject, id: request.id, chainId: request.chainId,
            body: request.body, workflowVersion: request.workflowVersion,
        }, nativeContext), NATIVE_OPERATION_TIMEOUT);
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
    finally { release(); }
}

async function ensureRecoveryAlarm(interval) {
    const context = WIRE.workerNativeContext(browser.extension?.inIncognitoContext);
    if (!context || context.privateBrowsing) { return; }
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

function sendNativeAdmission(message, nativeContext) {
    void ensureRecoveryAlarm(1);
    return sendNativeMessage(message, nativeContext);
}

function validRecoveryRequest(request) {
    return WIRE.configurationIdentityForURL(request.configurationKey)?.configurationKey === request.configurationKey;
}

function recoverRequests() {
    const nativeContext = WIRE.workerNativeContext(browser.extension?.inIncognitoContext);
    if (!nativeContext || nativeContext.privateBrowsing) { return Promise.resolve(); }
    if (recoveryFlight) { recoveryQueued = true; return recoveryFlight; }
    const pending = (async () => {
        void ensureRecoveryAlarm();
        const id = WIRE.genId();
        const rawResponse = await WIRE.withTimeout(sendNativeMessage({
            subject: "getRecoveryRequests", id, workflowVersion: WORKFLOW_VERSION,
        }, nativeContext), TRANSPORT_TIMEOUT);
        const response = WIRE.decodeMessage("NativeRecoveryReply", rawResponse);
        if (response?.id !== id || !response.requests?.every(validRecoveryRequest)) { return; }
        void ensureRecoveryAlarm(response.requests.length ? 1 : IDLE_RECOVERY_INTERVAL_MINUTES);
        if (response.requests.length === 0) { return; }
        const ready = [];
        for (const request of response.requests) {
            try {
                if (request.state !== "completed" || request.manual) {
                    const polled = await pollStoredResponse(request, nativeContext, request.state === "completed" ? "none" : "quiet");
                    if (!polled?.delivery) { continue; }
                    if (request.manual) {
                        await broadcastConfigurationInvalidated(request.configurationKey);
                        await acknowledgeCompletedResponse(request, nativeContext);
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

function beginManualSwitch(identity, nativeContext) {
    const pending = (async () => {
        let state = await readNativeConfiguration(identity.configurationKey, nativeContext);
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
            }, nativeContext), NATIVE_APPROVAL_TRANSPORT_TIMEOUT);
            if (WIRE.isNativeEnqueueAcknowledgement(response, response?.id) && response.state.context === state.context &&
                (response.admissionKind === "coalesced" || response.id === id)) {
                if (!response.approvalRequired && response.admissionKind === "coalesced") {
                    if (completionDrainUsed) { return undefined; }
                    completionDrainUsed = true;
                    const completed = await consumeStoredResponse({...response, configurationKey: identity.configurationKey}, nativeContext);
                    if (!completed?.delivery && !completed?.status?.missing) { return undefined; }
                    const refreshed = await readNativeConfiguration(identity.configurationKey, nativeContext);
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

async function handleManualSwitchIntent(request, nativeContext) {
    if (nativeContext?.source !== "site" || nativeContext.privateBrowsing) { return undefined; }
    return beginManualSwitch(nativeContext.site, nativeContext);
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
    if (context.privacy === "private") { return undefined; }
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

async function openNativeWallet(nativeContext) {
    try {
        await WIRE.withTimeout(sendNativeMessage({
            subject: "openApp",
            id: WIRE.genId(),
            workflowVersion: WORKFLOW_VERSION,
        }, nativeContext), NATIVE_APPROVAL_TRANSPORT_TIMEOUT);
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

async function showManualSwitchApproval(response, configurationKey, nativeContext) {
    const request = {
        subject: "showApproval", id: response.id, configurationKey,
        requestToken: response.requestToken, workflowVersion: WORKFLOW_VERSION,
    };
    for (let attempt = 0; attempt < 2; attempt += 1) {
        try {
            const opened = await WIRE.withTimeout(sendNativeMessage(request, nativeContext), NATIVE_APPROVAL_TRANSPORT_TIMEOUT);
            const status = WIRE.decodeMessage("NativeOpenReply", opened);
            if (status?.id !== response.id) { continue; }
            if (status.opened === true) {
                return true;
            }
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
    const privacy = WIRE.privacyForTab(tab, browser.extension?.inIncognitoContext);
    const nativeContext = WIRE.workerNativeContext(privacy === "unknown" ? undefined : privacy === "private");
    if (!nativeContext) {
        if (Number.isSafeInteger(tab?.id) && tab.id >= 0) { setToolbarFailure(tab.id, true); }
        return;
    }
    const identity = WIRE.configurationIdentityForURL(tab?.url || tab?.pendingUrl);
    if (!identity || !Number.isSafeInteger(tab?.id) || tab.id < 0 || nativeContext.privateBrowsing) {
        if (Number.isSafeInteger(tab?.id) && tab.id >= 0) {
            toolbarClicks.delete(tab.id);
            setToolbarFailure(tab.id, false);
        }
        await openNativeWallet(nativeContext);
        return;
    }
    const click = {url: tab.url || tab.pendingUrl};
    toolbarClicks.set(tab.id, click);
    const updateFailure = failed => {
        if (toolbarClicks.get(tab.id) === click) { setToolbarFailure(tab.id, failed); }
    };
    updateFailure(false);
    try {
        const response = await beginManualSwitch(identity, nativeContext);
        const acknowledged = WIRE.isManualSwitchAcknowledgement(response, response?.id, identity.configurationKey);
        const terminal = WIRE.isManualSwitchTerminalResponse(response, response?.id);
        const succeeded = acknowledged ? !response.approvalRequired ||
            await showManualSwitchApproval(response, identity.configurationKey, nativeContext)
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
    const nativeContext = WIRE.runtimeNativeContext(context, request);
    switch (request.subject) {
    case "rpc": return handleRPC(request, nativeContext);
    case "message-to-wallet": return handleDappRequest(request, nativeContext);
    case WIRE.MANUAL_SWITCH_INTENT_SUBJECT: return handleManualSwitchIntent(request, nativeContext);
    case "getResponse": return handleGetResponse(request, nativeContext);
    case "getLatestConfiguration": return latestConfiguration(request, nativeContext);
    case "applyCompletedResponse": return applyCompletedResponse(request, nativeContext);
    case "disconnect": return disconnect(request, nativeContext);
    case "updatePendingRequestBadge": await updateBadge(request, context); return undefined;
    case "responseReady":
        if (context.privacy !== "private") {
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
