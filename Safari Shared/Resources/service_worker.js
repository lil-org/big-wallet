// ∅ 2026 lil org

importScripts("bridge_wire.js");

const WIRE = BigWalletBridgeWire;
const WORKFLOW_VERSION = WIRE.WORKFLOW_VERSION;
const BUILD_VERSION = WIRE.BUILD_VERSION;
const APPLICATION_ID = "org.lil.wallet";
const UPDATE_RECOVERY_STORAGE_KEY = "workflowUpdateRecoveryNeeded";
const TRANSPORT_TIMEOUT = 5000;
const TAB_QUERY_TIMEOUT = 1000;
const MANUAL_SWITCH_INTENT_TIMEOUT = TRANSPORT_TIMEOUT * 8;
const NATIVE_OPERATION_TIMEOUT = 180 * 1000;
const MANUAL_SWITCH_RECOVERY_ALARM = "manualSwitchRecovery";
const REQUEST_MAINTENANCE_INTERVAL = 30 * 1000;
const requestMaintenanceTimes = new Map;
let recoveryFlight = null;
let recoveryQueued = false;
let alarmFlight = null;

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
    for (const status of ["pending", "ready", "missing", "unavailable"]) {
        if (WIRE.hasExactKeys(response, ["id", status]) && response.id === id && response[status] === true) {
            return response;
        }
    }
    return undefined;
}

function pageFailure(id, provider, name, message = "Failed to communicate with Big Wallet", code = -32603) {
    return {kind: "error", id, provider, name, state: null, error: {code, message}};
}

function pageConfigurationFailure() {
    return {kind: "configurationError", error: {code: 4900, message: "Failed to communicate with Big Wallet"}};
}

function decodedNativeDelivery(response, id) {
    if (WIRE.hasExactKeys(response, ["id", "response", "state"]) && response.id === id) {
        const terminal = WIRE.decodeNativeResponse(response.response, id);
        const state = WIRE.decodeConfigurationSnapshot(response.state);
        return terminal && state ? {terminal, state} : null;
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
    return WIRE.hasExactKeys(response, ["id", "state"]) && response.id === id
        ? WIRE.decodeConfigurationSnapshot(response.state) : null;
}

async function latestConfiguration(request, context) {
    const identity = requestIdentity(request, context);
    if (!identity || !WIRE.hasExactKeys(request, ["configurationKey", "host", "subject", "workflowVersion"]) ||
        request.workflowVersion !== WORKFLOW_VERSION) { return pageConfigurationFailure(); }
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
    if (!identity || !WIRE.hasExactKeys(request, ["admissionDeadline", "authority", "configurationKey",
            "enqueueAttempt", "host", "message", "subject", "workflowVersion"]) ||
        request.workflowVersion !== WORKFLOW_VERSION || !WIRE.isAuthorityVersion(request.authority) ||
        !Number.isSafeInteger(request.admissionDeadline) || request.admissionDeadline <= 0 ||
        !WIRE.isPrivateToken(request.enqueueAttempt) ||
        !WIRE.hasExactKeys(message, ["body", "id", "name", "provider"]) ||
        !WIRE.isValidRequestId(message.id) || typeof message.name !== "string" ||
        !WIRE.isRecord(message.body) || !["ethereum", "solana"].includes(message.provider)) { return undefined; }
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
    await ensureManualSwitchAlarm();
    const response = await WIRE.withTimeout(sendNativeMessage({
        ...message, ...identity, authority: request.authority,
        admissionDeadline: request.admissionDeadline, enqueueAttempt: request.enqueueAttempt,
        favicon: identity.configurationKey.startsWith("file:") ? ""
            : typeof context.favicon === "string" && context.favicon.length <= 16 * 1024 ? context.favicon : "",
        workflowVersion: WORKFLOW_VERSION,
    }, false), TRANSPORT_TIMEOUT);
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
    return !context.privateBrowsing && WIRE.hasExactKeys(request, [
        "configurationKey", "id", "requestToken", "subject", "workflowVersion",
    ]) && request.workflowVersion === WORKFLOW_VERSION &&
        context.identity?.configurationKey === request.configurationKey &&
        WIRE.isValidRequestId(request.id) && WIRE.isRequestToken(request.requestToken);
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
    const response = await WIRE.withTimeout(sendNativeMessage({
        ...nativeRequestIdentity(request),
        ...(maintain ? {subject: "maintainRequest", allowDelivery: true} : {subject: "getResponse"}),
    }, false), TRANSPORT_TIMEOUT);
    return nativeRequestStatus(response, request.id);
}

async function acknowledgeCompletedResponse(request) {
    const response = await WIRE.withTimeout(sendNativeMessage({
        ...nativeRequestIdentity(request), subject: "acknowledgeResponse",
    }, false), TRANSPORT_TIMEOUT);
    return response?.id === request.id && (
        WIRE.hasExactKeys(response, ["id", "acknowledged"]) && response.acknowledged === true ||
        WIRE.hasExactKeys(response, ["id", "missing"]) && response.missing === true);
}

function consumeStoredResponse(request) {
    const pending = (async () => {
        const response = await WIRE.withTimeout(sendNativeMessage({
            ...nativeRequestIdentity(request), subject: "prepareResponseDelivery",
        }, false), TRANSPORT_TIMEOUT);
        const status = nativeRequestStatus(response, request.id);
        if (status) { return {status}; }
        const delivery = decodedNativeDelivery(response, request.id);
        if (!delivery || !delivery.state || !await acknowledgeCompletedResponse(request)) { return undefined; }
        await broadcastConfigurationInvalidated(request.configurationKey);
        return {delivery};
    })();
    return pending;
}

async function consumeResponse(request, context) {
    if (!validContentResponseRequest(request, context)) { return undefined; }
    const completed = await consumeStoredResponse(request);
    return completed?.delivery ? pageResponse(completed.delivery) : completed?.status;
}

async function applyCompletedResponse(request, context) {
    if (context.privateBrowsing || !requestIdentity(request, context) ||
        !WIRE.hasExactKeys(request, ["configurationKey", "host", "id", "requestToken", "subject", "workflowVersion"]) ||
        request.workflowVersion !== WORKFLOW_VERSION || !WIRE.isValidRequestId(request.id) ||
        !WIRE.isRequestToken(request.requestToken)) { return undefined; }
    const completed = await consumeStoredResponse(request);
    return completed?.delivery ? {applied: true}
        : completed?.status?.missing ? completed.status : undefined;
}

async function disconnect(request, context) {
    if (!WIRE.isValidDisconnectRequest(request) || !requestIdentity(request, context) ||
        !WIRE.hasExactKeys(request, ["subject", "id", "provider", "host", "configurationKey", "attempt", "authority", "workflowVersion"]) ||
        !WIRE.isPrivateToken(request.attempt) || !WIRE.isAuthorityVersion(request.authority) ||
        request.workflowVersion !== WORKFLOW_VERSION || context.privateBrowsing) { return undefined; }
    const response = await WIRE.withTimeout(sendNativeMessage({
        subject: "disconnect", id: request.id, provider: request.provider,
        configurationKey: request.configurationKey, attempt: request.attempt, authority: request.authority,
        workflowVersion: WORKFLOW_VERSION,
    }, false), TRANSPORT_TIMEOUT);
    const state = WIRE.decodeConfigurationSnapshot(response?.state);
    if (response?.id !== request.id || !state) { return pageFailure(request.id, request.provider, "revokePermissions"); }
    if (WIRE.hasExactKeys(response, ["id", "state", "revoked"]) && response.revoked === true) {
        await broadcastConfigurationInvalidated(request.configurationKey);
        return {id: request.id, provider: request.provider, name: "revokePermissions",
            kind: "result", result: null, approvalCommitted: false, state};
    }
    if (WIRE.hasExactKeys(response, ["id", "state", "stale"]) && response.stale === true) {
        return {...pageFailure(request.id, request.provider, "revokePermissions", "Authorization changed while the request was pending", 4100), state};
    }
    return pageFailure(request.id, request.provider, "revokePermissions");
}

async function handleRPC(request, context) {
    if (!WIRE.hasExactKeys(request, ["body", "chainId", "id", "subject", "workflowVersion"]) ||
        request.workflowVersion !== WORKFLOW_VERSION || !WIRE.isValidRequestId(request.id) ||
        typeof request.body !== "string" || !WIRE.isCanonicalEthereumChainId(request.chainId) || context.privateBrowsing) {
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

function ensureManualSwitchAlarm() {
    if (alarmFlight) { return alarmFlight; }
    const pending = (async () => {
        if (!await browser.alarms.get(MANUAL_SWITCH_RECOVERY_ALARM)) {
            await browser.alarms.create(MANUAL_SWITCH_RECOVERY_ALARM, {delayInMinutes: 1, periodInMinutes: 1});
        }
    })();
    alarmFlight = pending;
    const clear = () => { if (alarmFlight === pending) { alarmFlight = null; } };
    pending.then(clear, clear);
    return pending;
}

function validRecoveryRequest(request) {
    return WIRE.hasExactKeys(request, ["id", "requestToken", "configurationKey", "manual", "state"]) &&
        WIRE.isValidRequestId(request.id) && WIRE.isRequestToken(request.requestToken) &&
        WIRE.configurationIdentityForURL(request.configurationKey)?.configurationKey === request.configurationKey &&
        typeof request.manual === "boolean" && ["pending", "approved", "completed"].includes(request.state);
}

function recoverRequests() {
    if (browser.extension?.inIncognitoContext === true) { return Promise.resolve(); }
    if (recoveryFlight) { recoveryQueued = true; return recoveryFlight; }
    const pending = (async () => {
        await ensureManualSwitchAlarm();
        const id = WIRE.genId();
        const response = await WIRE.withTimeout(sendNativeMessage({
            subject: "getRecoveryRequests", id, workflowVersion: WORKFLOW_VERSION,
        }, false), TRANSPORT_TIMEOUT);
        if (!WIRE.hasExactKeys(response, ["id", "requests"]) || response.id !== id ||
            !Array.isArray(response.requests) || response.requests.length > WIRE.WORKFLOW_POLICY.maximumRetainedRequests ||
            !response.requests.every(validRecoveryRequest)) { return; }
        const ready = [];
        for (const request of response.requests) {
            try {
                let status = request.state === "completed" ? {ready: true} : nativeRequestStatus(
                    await WIRE.withTimeout(sendNativeMessage({...nativeRequestIdentity(request),
                        subject: "maintainRequest", allowDelivery: false}, false), TRANSPORT_TIMEOUT), request.id);
                if (!status?.ready) { continue; }
                await broadcastConfigurationInvalidated(request.configurationKey);
                if (request.manual) { await consumeStoredResponse(request); }
                else { ready.push(request.id); }
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
        await ensureManualSwitchAlarm();
        let state = await readNativeConfiguration(identity.configurationKey);
        if (!state) { return undefined; }
        const admissionDeadline = Date.now() + WIRE.WORKFLOW_POLICY.requestTTLMilliseconds;
        let authorizationRetryUsed = false;
        let completionDrainUsed = false;
        let previousID = 0;
        for (let attempt = 0; attempt < 3; attempt += 1) {
            if (Date.now() >= admissionDeadline) { return undefined; }
            const id = Math.max(WIRE.genId(), previousID + 1);
            previousID = id;
            const response = await WIRE.withTimeout(sendNativeMessage({
                ...identity, id, name: "switchAccount", provider: "unknown", body: {},
                authority: {context: state.context, revisions: state.revisions},
                admissionDeadline, enqueueAttempt: WIRE.genPrivateToken(), workflowVersion: WORKFLOW_VERSION,
            }, false), TRANSPORT_TIMEOUT);
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
            if (!authorizationRetryUsed && delivery?.terminal.kind === "error" &&
                delivery.terminal.name === "switchAccount" && delivery.terminal.provider === "multiple" &&
                delivery.terminal.error.code === 4100 && delivery.state?.context === state.context &&
                delivery.state.revisions.ethereum >= state.revisions.ethereum &&
                delivery.state.revisions.solana >= state.revisions.solana &&
                (delivery.state.revisions.ethereum > state.revisions.ethereum ||
                    delivery.state.revisions.solana > state.revisions.solana) && Date.now() < admissionDeadline) {
                authorizationRetryUsed = true;
                state = delivery.state;
                continue;
            }
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
    if (context.privateBrowsing || !identity || !WIRE.hasExactKeys(request, ["configurationKey", "host", "subject", "workflowVersion"]) ||
        request.workflowVersion !== WORKFLOW_VERSION) { return undefined; }
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
    if (context.privateBrowsing ||
        !WIRE.hasExactKeys(request, [
            "hasPendingRequests", "subject", "workflowVersion",
        ]) || typeof request.hasPendingRequests !== "boolean" ||
        request.workflowVersion !== WORKFLOW_VERSION) {
        return undefined;
    }
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
        }, tab?.incognito === true), TRANSPORT_TIMEOUT);
    } catch {}
}

async function handleToolbarClick(tab) {
    if (hasConfiguredPopup()) { return; }
    const identity = WIRE.configurationIdentityForURL(tab?.url || tab?.pendingUrl);
    if (!identity || !Number.isSafeInteger(tab?.id) || tab?.incognito === true) {
        await openNativeWallet(tab);
        return;
    }
    const nonce = WIRE.genPrivateToken();
    let probe;
    try {
        probe = await WIRE.withTimeout(browser.tabs.sendMessage(tab.id, {
            nonce,
            subject: "workflowProbe",
            workflowVersion: WORKFLOW_VERSION,
        }), TAB_QUERY_TIMEOUT);
    } catch {
        await openNativeWallet(tab);
        return;
    }
    if (!WIRE.hasExactKeys(probe, [
            "buildVersion", "nonce", "subject", "workflowVersion",
        ]) || probe.subject !== "workflowProbe" || probe.nonce !== nonce ||
        typeof probe.buildVersion !== "string" ||
        probe.buildVersion.length === 0 ||
        !Number.isSafeInteger(probe.workflowVersion)) {
        await openNativeWallet(tab);
        return;
    }
    if (probe.workflowVersion !== WORKFLOW_VERSION ||
        probe.buildVersion !== BUILD_VERSION) {
        await openNativeWallet(tab);
        return;
    }
    let response;
    try {
        response = await WIRE.withTimeout(
            browser.tabs.sendMessage(tab.id, {
                configurationKey: identity.configurationKey,
                subject: WIRE.MANUAL_SWITCH_INTENT_SUBJECT,
                workflowVersion: WORKFLOW_VERSION,
            }),
            MANUAL_SWITCH_INTENT_TIMEOUT
        );
    } catch {
        await openNativeWallet(tab);
        return;
    }
    const valid = WIRE.isManualSwitchAcknowledgement(
        response,
        response?.id,
        identity.configurationKey
    ) || WIRE.isManualSwitchTerminalResponse(response, response?.id);
    if (!valid || response.kind === "error") {
        await openNativeWallet(tab);
    } else if (WIRE.isManualSwitchAcknowledgement(
        response,
        response.id,
        identity.configurationKey
    ) && response.approvalRequired) {
        try {
            await WIRE.withTimeout(sendNativeMessage({
                subject: "showApproval",
                id: response.id,
                configurationKey: identity.configurationKey,
                requestToken: response.requestToken,
                workflowVersion: WORKFLOW_VERSION,
            }, false), TRANSPORT_TIMEOUT);
        } catch {}
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
    switch (request.subject) {
    case "rpc": return handleRPC(request, context);
    case "message-to-wallet": return handleDappRequest(request, context);
    case WIRE.MANUAL_SWITCH_INTENT_SUBJECT: return handleManualSwitchIntent(request, context);
    case "getResponse": return handleGetResponse(request, context);
    case "consumeResponse": return consumeResponse(request, context);
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
    browser.action?.onClicked?.addListener?.(tab => {
        Promise.resolve(handleToolbarClick(tab)).catch(() => {});
    });
} catch {}
