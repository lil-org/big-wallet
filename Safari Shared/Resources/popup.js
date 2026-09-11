// ∅ 2026 lil org

const IS_DESKTOP_POPUP = navigator.maxTouchPoints === 0;

if (IS_DESKTOP_POPUP && document.documentElement) {
    document.documentElement.classList.add("desktop");
}

const TRANSACTION_REFRESH_INTERVAL = 600;
const TRANSACTION_REFRESH_MAX_INTERVAL = 10000;
const APPROVAL_POLL_INTERVAL = 400;
const NATIVE_MESSAGE_TIMEOUT = 5000;
const MANUAL_SWITCH_TIMEOUT = NATIVE_MESSAGE_TIMEOUT * 2;
const NATIVE_OPERATION_RELAY_TIMEOUT = 190 * 1000;
const MAX_RESPONSE_READY_IDS = BigWalletBridgeWire.MAX_RESPONSE_READY_IDS;
const WORKFLOW_VERSION = BigWalletBridgeWire.WORKFLOW_VERSION;
const BUILD_VERSION = BigWalletBridgeWire.BUILD_VERSION;
const UPDATE_RECOVERY_STORAGE_KEY = "workflowUpdateRecoveryNeeded";
const WORKFLOW_POLICY = BigWalletBridgeWire.WORKFLOW_POLICY;
const APPROVAL_STATES = new Set(["missing", "review", "authenticating", "working", "error"]);
const APPROVAL_KINDS = new Set([
    "selectAccount",
    "switchAccount",
    "signMessage",
    "sendTransaction",
    "addChain",
]);
const SELECTION_ACCOUNT_COINS = new Set(WORKFLOW_POLICY.selectionAccountCoins);
const SOLANA_CLUSTER_VALUES = new Set(WORKFLOW_POLICY.solanaClusterValues);
const TRANSACTION_PHASES = new Set([
    "idle",
    "preparing",
    "ready",
    "failed",
    "editing",
    "authenticating",
    "preflighting",
    "reviewingFees",
    "finished",
]);
const STABLE_TRANSACTION_PHASES = new Set([
    "ready",
    "failed",
    "reviewingFees",
    "finished",
]);
const ALERT_ACTIONS = new Set(["acknowledge", "retry", "edit", "cancel"]);
var configurationIdentityForURL = BigWalletBridgeWire.configurationIdentityForURL;
var genId = BigWalletBridgeWire.genId;
var genPrivateToken = BigWalletBridgeWire.genPrivateToken;
var hasExactKeys = BigWalletBridgeWire.hasExactKeys;
var isConfiguration = BigWalletBridgeWire.isConfiguration;
var isCanonicalEthereumChainId = BigWalletBridgeWire.isCanonicalEthereumChainId;
var isRequestToken = BigWalletBridgeWire.isRequestToken;
var isPendingRequestAvailable = BigWalletBridgeWire.isPendingRequestAvailable;
var isPrivateToken = BigWalletBridgeWire.isPrivateToken;
var isProviderRevisions = BigWalletBridgeWire.isProviderRevisions;
var isRecord = BigWalletBridgeWire.isRecord;
var isValidRequestId = BigWalletBridgeWire.isValidRequestId;
var withTimeout = BigWalletBridgeWire.withTimeout;

const queueTab = {
    activeTab: null,
    booting: true,
    contentScriptUnavailableTab: null,
    domReady: false,
    items: [],
    index: 0,
    lastRefreshFailed: false,
    privateBrowsing: extensionPrivateBrowsing(),
    refreshGeneration: 0,
    refreshInFlight: null,
    refreshRequested: false,
    refreshTimer: null,
    snapshotStatus: "unknown",
    updateRecoveryTab: null,
};
const approvalLifecycle = {
    current: null,
    pollTimer: null,
    refreshTimer: null,
    completion: null,
    mutation: null,
    generation: 0,
};
const selectionRender = {
    accounts: null,
    chainId: null,
    networksKey: null,
    cluster: null,
    idleGeneration: 0,
    lastStateJSON: null,
    strings: {},
    alertKey: null,
    alertReturnFocus: null,
};
const transactionInteraction = {
    sliderDragging: false,
    sliderRequest: null,
    sliderReviewToken: null,
    ignoreSliderUntilRelease: false,
    activeCommand: null,
    generation: 0,
    lastEditorRequestKey: null,
    editorDirty: false,
};
const transactionRefresh = {
    delay: TRANSACTION_REFRESH_INTERVAL,
};
const NATIVE_MESSAGE_CANCELLED = Symbol("nativeMessageCancelled");
const nativeChannels = { read: Promise.resolve(), action: Promise.resolve() };
let unresolvedOpenAppCall = null;

function extensionPrivateBrowsing() {
    return browser.extension?.inIncognitoContext === true;
}

function currentPrivateBrowsing() {
    return typeof queueTab.activeTab?.incognito === "boolean"
        ? queueTab.activeTab.incognito
        : queueTab.privateBrowsing;
}

function sendRawNativeMessage(message) {
    return browser.runtime.sendNativeMessage("org.lil.wallet", message);
}

var sendTrustedNativeMessage =
    BigWalletBridgeWire.createTrustedNativeMessageSender({
        sendRawNativeMessage,
    });

function nativeMessage(
    subject,
    id,
    payload,
    requestToken,
    reviewToken,
    approvalRequest
) {
    if (typeof payload !== "undefined" && !isRecord(payload)) {
        return Promise.reject(new TypeError("Invalid popup payload"));
    }
    if (isRecord(payload) && Object.prototype.hasOwnProperty.call(
        payload,
        "password"
    )) {
        return Promise.reject(new TypeError("Password payloads are not supported"));
    }
    const message = {
        subject: subject,
        id: id,
        workflowVersion: WORKFLOW_VERSION,
    };
    if (typeof requestToken !== "undefined") {
        message.requestToken = requestToken;
    }
    if (typeof reviewToken !== "undefined") {
        message.reviewToken = reviewToken;
    }
    if (typeof payload !== "undefined") {
        message.payload = payload;
    }
    if (subject === "approveRequest") {
        if (!isRecord(approvalRequest) ||
            typeof approvalRequest.host !== "string" ||
            typeof approvalRequest.configurationKey !== "string") {
            return Promise.reject(new TypeError("Invalid approval request"));
        }
        return browser.runtime.sendMessage({
            subject: "approveRequestWithCurrentRevisions",
            id,
            host: approvalRequest.host,
            configurationKey: approvalRequest.configurationKey,
            requestToken,
            reviewToken,
            payload: payload || {},
            privateBrowsing: currentPrivateBrowsing(),
            workflowVersion: WORKFLOW_VERSION,
        });
    }
    return sendTrustedNativeMessage(message, currentPrivateBrowsing());
}

function scheduleNativeMessage(kind, subject, id, payload, requestToken, options = {}) {
    const channel = kind === "queue" || kind === "approval" ? "read" : "action";
    const ticket = { cancelled: false, state: "waiting" };
    ticket.cancel = () => {
        if (ticket.state !== "waiting") { return false; }
        ticket.cancelled = true;
        ticket.state = "cancelled";
        return true;
    };
    const predecessor = nativeChannels[channel];
    let releaseChannel;
    let channelReleased = false;
    const channelOccupancy = new Promise(resolve => { releaseChannel = resolve; });
    const release = () => {
        if (channelReleased) { return; }
        channelReleased = true;
        releaseChannel();
    };
    nativeChannels[channel] = channelOccupancy;
    const operation = predecessor.then(async () => {
        if (ticket.cancelled || options.isValid && !options.isValid()) {
            release();
            return { status: "cancelled" };
        }
        const reviewToken = channel === "action"
            ? Object.prototype.hasOwnProperty.call(options, "reviewToken")
                ? options.reviewToken
                : approvalLifecycle.current?.reviewToken
            : undefined;
        ticket.state = "dispatched";
        let pendingResponse;
        try {
            pendingResponse = Promise.resolve(nativeMessage(
                subject,
                id,
                payload,
                requestToken,
                reviewToken,
                options.approvalRequest
            ));
        } catch {
            release();
            ticket.state = "settled";
            return {status: "failure"};
        }
        try {
            const response = await settleNativeMessage(
                pendingResponse,
                subject === "approveRequest"
            );
            return { response: response, status: "response" };
        } catch {
            return { status: "failure" };
        } finally {
            release();
            ticket.state = "settled";
        }
    });
    ticket.result = operation;
    return ticket;
}

function cancelNativeMessageTicket(ticket) {
    return ticket?.cancel?.() === true;
}

async function settleNativeMessage(pendingResponse, nativeOperation = false) {
    return withTimeout(
        pendingResponse,
        nativeOperation
            ? NATIVE_OPERATION_RELAY_TIMEOUT
            : NATIVE_MESSAGE_TIMEOUT
    );
}

async function settleExtensionMessage(
    pendingResponse,
    milliseconds = NATIVE_MESSAGE_TIMEOUT
) {
    try {
        return {
            response: await withTimeout(pendingResponse, milliseconds),
            status: "response",
        };
    } catch (error) {
        return {status: error?.name === "TimeoutError" ? "timeout" : "failure"};
    }
}

function show(id) {
    document.getElementById(id).classList.remove("hidden");
}

function hide(id) {
    document.getElementById(id).classList.add("hidden");
}

function setHidden(id, hidden) {
    if (hidden) {
        hide(id);
    } else {
        show(id);
    }
}

function setText(id, text) {
    document.getElementById(id).textContent = text;
}

function setOptionalText(textId, rowId, value) {
    if (value) {
        setText(textId, value);
    }
    setHidden(rowId, !value);
}

function closeAlert(restoreFocus) {
    const overlay = document.getElementById("alert-overlay");
    const wasOpen = selectionRender.alertKey !== null || !overlay.classList.contains("hidden");
    const focusTarget = selectionRender.alertReturnFocus;
    hide("alert-overlay");
    document.getElementById("screen-request").inert = false;
    document.getElementById("alert-buttons").innerHTML = "";
    selectionRender.alertKey = null;
    selectionRender.alertReturnFocus = null;
    if (restoreFocus && wasOpen && focusTarget &&
        focusTarget.isConnected !== false && focusTarget.disabled !== true &&
        typeof focusTarget.focus === "function") {
        focusTarget.focus();
    }
}

function localized(key, fallback) {
    return selectionRender.strings[key] || fallback;
}

function formatted(template, ...values) {
    return values.reduce(
        (text, value, index) => text.split("%" + (index + 1) + "$@").join(value),
        template
    );
}

// The popup is HTML, so the wallet ships its localized chrome with the first native response.
// The English in popup.html stays as the fallback for when that response never arrives.
function applyStrings(dictionary) {
    if (!dictionary) { return; }
    selectionRender.strings = dictionary;
    for (const element of document.querySelectorAll("[data-string]")) {
        const text = selectionRender.strings[element.dataset.string];
        if (text) {
            element.textContent = text;
        }
    }
}

// The popup is HTML in an extension bundle, so nothing mirrors it the way UIKit and AppKit
// mirror the rest of the wallet. The direction rides along with the localized chrome.
function applyLayoutDirection(direction) {
    if (direction && document.documentElement) {
        document.documentElement.dir = direction;
    }
}

function privateBrowsingForTab(tab, windowIncognito) {
    return typeof tab?.incognito === "boolean"
        ? tab.incognito
        : typeof windowIncognito === "boolean"
            ? windowIncognito
            : true;
}

function tabIdentity(tab, windowIncognito) {
    if (!tab || tab.id == null || typeof tab.url !== "string") { return null; }
    const identity = configurationIdentityForURL(tab.url);
    const incognito = privateBrowsingForTab(tab, windowIncognito);
    return identity ? { id: tab.id, incognito, url: tab.url, ...identity } : null;
}

async function boot() {
    try {
        queueTab.activeTab = await currentActiveTab();
        queueTab.updateRecoveryTab = await readUpdateRecoveryFlag()
            ? await updateRecoveryTabFor(queueTab.activeTab)
            : null;
    } finally {
        queueTab.booting = false;
    }
    await refreshQueue();
    schedulePendingQueueRefresh();
}

function requestPendingQueueRefresh() {
    queueTab.refreshRequested = true;
    queueTab.refreshGeneration += 1;
    queueTab.snapshotStatus = "unknown";
    if (queueTab.domReady) {
        document.getElementById("idle-switch-account").disabled = true;
    }
    schedulePendingQueueRefresh();
}

function shouldDeferQueueRefreshForCurrentRequest() {
    const currentRequest = queueTab.items[queueTab.index];
    if (!currentRequest || sameRequest(approvalLifecycle.completion, currentRequest)) {
        return false;
    }
    return !document.getElementById("screen-request").classList.contains("hidden") ||
        document.getElementById("screen-idle").classList.contains("hidden");
}

function schedulePendingQueueRefresh() {
    if (!queueTab.domReady || queueTab.booting || !queueTab.refreshRequested ||
        queueTab.refreshTimer !== null ||
        queueTab.refreshInFlight !== null ||
        shouldDeferQueueRefreshForCurrentRequest()) {
        return;
    }
    queueTab.refreshTimer = setTimeout(() => {
        queueTab.refreshTimer = null;
        if (!queueTab.refreshRequested || queueTab.refreshInFlight !== null ||
            shouldDeferQueueRefreshForCurrentRequest()) {
            return;
        }
        void refreshQueue();
    }, 0);
}

function handlePopupRuntimeMessage(request) {
    if (isPendingRequestAvailable(request)) {
        requestPendingQueueRefresh();
    }
}

async function currentActiveTab() {
    const lookupDeadline = Date.now() + NATIVE_MESSAGE_TIMEOUT;
    let tabs;
    let pendingTabs;
    let tabsLookupTimedOut = false;
    try {
        pendingTabs = browser.tabs.query({ active: true, currentWindow: true });
    } catch {}
    if (pendingTabs) {
        const outcome = await settleExtensionMessage(
            pendingTabs,
            Math.max(0, lookupDeadline - Date.now())
        );
        tabsLookupTimedOut = outcome.status === "timeout";
        tabs = outcome.status === "response" ? outcome.response : null;
    }
    const tab = Array.isArray(tabs) ? tabs[0] : null;
    if (typeof tab?.incognito === "boolean") {
        queueTab.privateBrowsing = tab.incognito;
        return tabIdentity(tab);
    }
    let windowIncognito;
    if (!tabsLookupTimedOut && browser.windows &&
        typeof browser.windows.getCurrent === "function") {
        let pendingWindow;
        try {
            pendingWindow = browser.windows.getCurrent();
        } catch {
            windowIncognito = true;
        }
        if (typeof windowIncognito !== "boolean") {
            const outcome = await settleExtensionMessage(
                pendingWindow,
                Math.max(0, lookupDeadline - Date.now())
            );
            windowIncognito = outcome.status === "response" &&
                typeof outcome.response?.incognito === "boolean"
                ? outcome.response.incognito
                : true;
        }
    }
    queueTab.privateBrowsing = privateBrowsingForTab(tab, windowIncognito);
    return tabIdentity(tab, windowIncognito);
}

async function readUpdateRecoveryFlag() {
    let pendingFlag;
    try {
        pendingFlag = browser.storage.local.get(UPDATE_RECOVERY_STORAGE_KEY);
    } catch {
        return null;
    }
    const flag = await settleExtensionMessage(pendingFlag);
    return flag.status === "response" &&
        flag.response?.[UPDATE_RECOVERY_STORAGE_KEY] === true;
}

async function updateRecoveryTabFor(tab) {
    if (!tab || !Number.isSafeInteger(tab.id) || tab.incognito === true) {
        return null;
    }
    if (typeof browser.permissions?.contains === "function") {
        let origin;
        try {
            const url = new URL(tab.url || tab.configurationKey);
            origin = url.protocol === "file:" ? "file:///*" : `${url.origin}/*`;
        } catch {
            return null;
        }
        let pendingPermission;
        try {
            pendingPermission = browser.permissions.contains({origins: [origin]});
        } catch {
            return null;
        }
        const permission = await settleExtensionMessage(pendingPermission);
        if (permission.status !== "response" || permission.response !== true) {
            return null;
        }
    }
    let pendingProbe;
    const nonce = genPrivateToken();
    try {
        pendingProbe = browser.tabs.sendMessage(tab.id, {
            nonce,
            subject: "workflowProbe",
            workflowVersion: WORKFLOW_VERSION,
        });
    } catch {
        return null;
    }
    const probe = await settleExtensionMessage(pendingProbe);
    if (probe.status === "timeout") { return tab; }
    if (probe.status !== "response") { return null; }
    if (hasExactKeys(probe.response, [
        "buildVersion", "nonce", "subject", "workflowVersion",
    ]) && probe.response.nonce === nonce &&
        typeof probe.response.buildVersion === "string" &&
        probe.response.subject === "workflowProbe" &&
        probe.response.workflowVersion === WORKFLOW_VERSION) {
        return probe.response.buildVersion === BUILD_VERSION ? null : tab;
    }
    return typeof probe.response === "undefined" ? tab : null;
}

function sameTab(left, right) {
    return !!left && !!right &&
        left.id === right.id &&
        left.incognito === right.incognito &&
        left.configurationKey === right.configurationKey;
}

function sameUpdateRecoveryTab(left, right) {
    return !!left && !!right &&
        left.id === right.id &&
        left.incognito === right.incognito &&
        left.configurationKey === right.configurationKey &&
        typeof left.url === "string" && left.url === right.url;
}

function notifyResponseReadyIds(ids) {
    if (!Array.isArray(ids) || ids.length === 0) { return; }
    const validIds = [...new Set(ids.filter(isValidRequestId))];
    if (validIds.length === 0) { return; }
    for (let index = 0; index < validIds.length; index += MAX_RESPONSE_READY_IDS) {
        try {
            Promise.resolve(browser.runtime.sendMessage({
                subject: "responseReady",
                ids: validIds.slice(index, index + MAX_RESPONSE_READY_IDS),
                workflowVersion: WORKFLOW_VERSION,
            })).catch(() => {});
        } catch {}
    }
}

async function readLatestConfiguration(tab) {
    let pending;
    try {
        pending = browser.runtime.sendMessage({
            subject: "getLatestConfiguration",
            host: tab.host,
            configurationKey: tab.configurationKey,
            workflowVersion: WORKFLOW_VERSION,
        });
    } catch {
        return null;
    }
    const outcome = await settleExtensionMessage(pending);
    const configuration = outcome.status === "response" ? outcome.response : null;
    if (!configuration || configuration.configurationReadFailed === true ||
        !Array.isArray(configuration.latestConfigurations) ||
        !configuration.latestConfigurations.every(isConfiguration) ||
        !isProviderRevisions(configuration.revisions)) {
        return null;
    }
    return configuration;
}

function setPendingRequestBadge(count) {
    if (currentPrivateBrowsing()) { return; }
    try {
        Promise.resolve(browser.runtime.sendMessage({
            subject: "updatePendingRequestBadge",
            hasPendingRequests: count > 0,
            workflowVersion: WORKFLOW_VERSION,
        })).catch(() => {});
    } catch {}
}

// A failed native round trip is not an empty queue: the stored requests are still out there,
// so callers get null and leave the badge — the only remaining cue on platforms where the
// popup cannot open itself — exactly as it was.
async function fetchPendingResponse() {
    while (true) {
        const ticket = scheduleNativeMessage(
            "queue",
            "getPendingRequests",
            genId(),
            undefined,
            undefined
        );
        const outcome = await ticket.result;
        if (outcome.status !== "response") { return null; }
        const response = parsePendingResponse(outcome.response);
        if (!response) { return null; }
        applyStrings(response.strings);
        applyLayoutDirection(response.layoutDirection);
        const appliedIDs = [];
        for (const completed of response.completedResponses) {
            const result = await applyCompletedResponse(completed);
            if (result === "failure") {
                notifyResponseReadyIds(appliedIDs);
                return null;
            }
            if (result === "applied") { appliedIDs.push(completed.id); }
        }
        notifyResponseReadyIds(appliedIDs);
        if (response.completedResponses.length === 0) { return response; }
    }
}

async function performQueueRefresh() {
    while (true) {
        queueTab.refreshRequested = false;
        const generation = queueTab.refreshGeneration;
        const pendingResponse = await fetchPendingResponse();
        const requests = pendingResponse?.requests ?? null;
        if (generation !== queueTab.refreshGeneration) { continue; }
        if (shouldDeferQueueRefreshForCurrentRequest()) {
            queueTab.refreshRequested = true;
            return null;
        }
        showQueue(requests);
        return requests;
    }
}

function refreshQueue() {
    if (queueTab.refreshInFlight !== null) {
        return queueTab.refreshInFlight;
    }
    stopTimers();
    queueTab.snapshotStatus = "unknown";
    if (queueTab.domReady) {
        document.getElementById("idle-switch-account").disabled = true;
    }
    const operation = (async () => {
        try {
            return await performQueueRefresh();
        } finally {
            if (queueTab.refreshInFlight === operation) {
                queueTab.refreshInFlight = null;
            }
            if (queueTab.domReady &&
                document.getElementById("screen-request").classList.contains("hidden") &&
                !document.getElementById("screen-idle").classList.contains("hidden")) {
                renderIdleSwitchControls(false);
            }
            schedulePendingQueueRefresh();
        }
    })();
    queueTab.refreshInFlight = operation;
    return operation;
}

function showQueue(requests) {
    approvalLifecycle.generation += 1;
    selectionRender.idleGeneration += 1;
    closeAlert(false);
    const fetchFailed = requests === null;
    if (fetchFailed) {
        requests = [];
    }
    queueTab.lastRefreshFailed = fetchFailed;
    queueTab.snapshotStatus = fetchFailed
        ? "unknown"
        : (requests.length === 0 ? "empty" : "nonempty");
    queueTab.items = requests;
    queueTab.index = 0;
    if (!fetchFailed) {
        setPendingRequestBadge(queueTab.items.length);
    }
    hide("screen-loading");
    if (fetchFailed) {
        showIdle(true);
    } else if (queueTab.items.length === 0) {
        showIdle();
    } else {
        hide("screen-idle");
        showCurrentRequest();
    }
    schedulePendingQueueRefresh();
}

function shouldShowUpdateRecovery() {
    return queueTab.updateRecoveryTab !== null &&
        queueTab.snapshotStatus === "empty" && queueTab.items.length === 0;
}

function canBeginIdleSwitch() {
    return !currentPrivateBrowsing() &&
        queueTab.activeTab !== null &&
        queueTab.updateRecoveryTab === null &&
        queueTab.snapshotStatus === "empty" &&
        queueTab.items.length === 0 &&
        queueTab.refreshInFlight === null &&
        queueTab.refreshTimer === null &&
        queueTab.refreshRequested === false &&
        document.getElementById("screen-request").classList.contains("hidden");
}

async function showIdle(queueFetchFailed = false) {
    const generation = ++selectionRender.idleGeneration;
    approvalLifecycle.current = null;
    hide("screen-request");
    hide("working-overlay");
    show("screen-idle");
    schedulePendingQueueRefresh();
    // A failed queue fetch is not an empty queue, and saying "not connected" would report the one
    // thing the popup does not know.
    if (queueFetchFailed) {
        renderIdleSwitchControls(false);
        setHidden("idle-check-status", false);
        setText("idle-host", queueTab.activeTab ? (queueTab.activeTab.host || queueTab.activeTab.configurationKey) : "");
        setText("idle-connection", localized("failedToLoad", "Failed to load"));
        return;
    }
    if (!queueTab.activeTab) {
        renderIdleSwitchControls(false);
        setText("idle-host", "");
        setText("idle-connection", localized("noActivePage", "No active page"));
        return;
    }
    setText("idle-host", queueTab.activeTab.host || queueTab.activeTab.configurationKey);
    renderIdleSwitchControls(false);
    if (shouldShowUpdateRecovery()) {
        setHidden("idle-check-status", false);
        setText("idle-connection", localized("failedToLoad", "Failed to load"));
        return;
    }
    let connectionText = localized("notConnected", "Not connected");
    if (currentPrivateBrowsing()) {
        setText(
            "idle-connection",
            localized("privateBrowsingUnsupported",
                "Big Wallet requests are unavailable in Private Browsing."
            )
        );
        return;
    }
    const configuration = await readLatestConfiguration(queueTab.activeTab);
    if (generation !== selectionRender.idleGeneration) { return; }
    if (configuration) {
        const latest = configuration.latestConfigurations;
        const lines = [];
        for (const item of latest) {
            if (item.provider === "ethereum" && item.results && item.results[0]) {
                lines.push(item.results[0]);
            } else if (item.provider === "solana" && item.publicKey) {
                lines.push(item.publicKey);
            }
        }
        if (lines.length > 0) {
            connectionText = lines.join("\n");
        }
    } else {
        connectionText = localized("failedToLoad", "Failed to load");
    }
    setText("idle-connection", connectionText);
}

function renderIdleSwitchControls(pending) {
    const canOpenApp = IS_DESKTOP_POPUP && (
        queueTab.activeTab === null ||
        sameTab(queueTab.contentScriptUnavailableTab, queueTab.activeTab)
    );
    setHidden("idle-open-app", !canOpenApp);
    const switchButton = document.getElementById("idle-switch-account");
    const canSwitch = canBeginIdleSwitch();
    const privateBrowsing = currentPrivateBrowsing();
    setHidden(
        "idle-switch-account",
        privateBrowsing || !canSwitch
    );
    setHidden("idle-check-status", !queueTab.lastRefreshFailed && !shouldShowUpdateRecovery());
    setHidden("idle-pending-spinner", true);
    switchButton.disabled = privateBrowsing || !canSwitch;
}

function showCurrentRequest() {
    const request = queueTab.items[queueTab.index];
    if (!request) {
        refreshQueue();
        return;
    }
    if (queueTab.items.length > 1) {
        setText("queue-indicator", formatted(localized("queuePosition", "%1$@ of %2$@"),
                                             String(queueTab.index + 1), String(queueTab.items.length)));
        show("queue-indicator");
    } else {
        hide("queue-indicator");
    }
    resetSelections();
    fetchAndRenderState(request);
}

function requestFor(value) {
    const request = queueTab.items[queueTab.index];
    if (!request) { return null; }
    if (typeof value === "undefined") { return request; }
    if (isRecord(value)) { return value; }
    return request.id === value ? request : null;
}

function sameRequest(left, right) {
    return !!left && !!right &&
        left.id === right.id &&
        left.requestToken === right.requestToken;
}

function isCurrentRequest(request) {
    return sameRequest(request, queueTab.items[queueTab.index]);
}

function isApprovalStateEnvelope(state, request) {
    return isRecord(state) &&
        isValidRequestId(state.id) && state.id === request.id &&
        APPROVAL_STATES.has(state.state);
}

function isOptionalString(value) {
    return typeof value === "undefined" || typeof value === "string";
}

function isOptionalBoolean(value) {
    return typeof value === "undefined" || typeof value === "boolean";
}

function isPendingRequest(request) {
    return isRecord(request) &&
        isValidRequestId(request.id) &&
        isRequestToken(request.requestToken) &&
        (typeof request.enqueueAttempt === "undefined" ||
            isPrivateToken(request.enqueueAttempt)) &&
        Number.isSafeInteger(request.sequence) && request.sequence >= 0 &&
        typeof request.host === "string" && request.host.length > 0 &&
        typeof request.configurationKey === "string" &&
        request.configurationKey.length > 0 &&
        (request.provider === "ethereum" || request.provider === "solana" ||
            request.provider === "unknown") &&
        isProviderRevisions(request.revisions) &&
        typeof request.receivedAt === "number" && Number.isFinite(request.receivedAt);
}

function isCompletedResponse(response) {
    return hasExactKeys(response, [
            "configurationKey", "host", "id", "requestToken", "revisions",
        ]) &&
        isValidRequestId(response.id) &&
        typeof response.host === "string" && response.host.length > 0 &&
        typeof response.configurationKey === "string" &&
        response.configurationKey.length > 0 &&
        isRequestToken(response.requestToken) &&
        isProviderRevisions(response.revisions);
}

function parsePendingResponse(response) {
    if (!isRecord(response) ||
        !Array.isArray(response.requests) ||
        !response.requests.every(isPendingRequest) ||
        !Array.isArray(response.completedResponses) ||
        !response.completedResponses.every(isCompletedResponse) ||
        (typeof response.strings !== "undefined" &&
            (!isRecord(response.strings) ||
                !Object.values(response.strings).every(value => typeof value === "string"))) ||
        (typeof response.layoutDirection !== "undefined" &&
            response.layoutDirection !== "ltr" && response.layoutDirection !== "rtl")) {
        return null;
    }
    return {
        layoutDirection: response.layoutDirection,
        requests: response.requests.slice(),
        completedResponses: response.completedResponses.slice(),
        strings: response.strings,
    };
}

function isDisplayAccount(account) {
    return isRecord(account) &&
        typeof account.name === "string" &&
        typeof account.croppedAddress === "string" &&
        isOptionalString(account.icon);
}

function isAlert(alert) {
    return typeof alert === "undefined" ||
        isRecord(alert) &&
        typeof alert.title === "string" &&
        typeof alert.message === "string" &&
        Array.isArray(alert.actions) &&
        alert.actions.length > 0 &&
        alert.actions.every(action =>
            isRecord(action) &&
            typeof action.title === "string" &&
            ALERT_ACTIONS.has(action.action)
        );
}

function hasValidOptionalApprovalFields(state) {
    return isOptionalString(state.title) &&
        (typeof state.reviewToken === "undefined" ||
            isRequestToken(state.reviewToken)) &&
        (typeof state.host === "undefined" ||
            typeof state.host === "string" && state.host.length > 0) &&
        isOptionalString(state.iconURL) &&
        isOptionalString(state.primaryTitle) &&
        isOptionalString(state.error) &&
        isOptionalBoolean(state.canReject) &&
        isOptionalBoolean(state.secureSetupRequired) &&
        isOptionalBoolean(state.editsError) &&
        isAlert(state.alert);
}

function hasUniqueValues(items, valueFor) {
    return new Set(items.map(valueFor)).size === items.length;
}

function normalizedAccountAddress(account) {
    return account.coin === "ethereum" ? account.address.toLowerCase() : account.address;
}

function accountIdentityKey(account) {
    return JSON.stringify([
        account.walletId,
        account.coin,
        normalizedAccountAddress(account),
        account.derivationPath,
    ]);
}

function isSelectionState(state) {
    if (!Array.isArray(state.accounts) || !state.accounts.every(account =>
        isDisplayAccount(account) &&
        typeof account.walletId === "string" &&
            SELECTION_ACCOUNT_COINS.has(account.coin) &&
            typeof account.address === "string" &&
            typeof account.derivationPath === "string" &&
            account.derivationPath.length > 0 &&
            typeof account.isSelected === "boolean"
    )) {
        return false;
    }
    if (!hasUniqueValues(state.accounts, accountIdentityKey) ||
        !hasUniqueValues(state.accounts.filter(account => account.isSelected), account => account.coin)) {
        return false;
    }
    if (typeof state.networks !== "undefined" &&
        (!Array.isArray(state.networks) || !state.networks.every(network =>
            isRecord(network) &&
            isCanonicalEthereumChainId(network.chainId) &&
            typeof network.name === "string" &&
            typeof network.isSelected === "boolean" &&
            isOptionalBoolean(network.isCustom)
        ) ||
        !hasUniqueValues(state.networks, network => network.chainId) ||
        state.networks.filter(network => network.isSelected).length > 1)) {
        return false;
    }
    return typeof state.canSelectNetwork === "boolean" &&
        typeof state.allowsEmptySelection === "boolean" &&
        isOptionalString(state.emptyMessage) &&
        (!state.accounts.some(account => account.coin === "ethereum") ||
            state.canSelectNetwork) &&
        (!state.canSelectNetwork || Array.isArray(state.networks));
}

function isSignMessageState(state) {
    if (!isDisplayAccount(state.account) || typeof state.meta !== "string") {
        return false;
    }
    const hasClusters = typeof state.clusters !== "undefined";
    const hasRequirement = typeof state.requiresClusterSelection !== "undefined";
    if (hasClusters !== hasRequirement) {
        return false;
    }
    if (!hasClusters) {
        return true;
    }
    if (typeof state.requiresClusterSelection !== "boolean" ||
        !Array.isArray(state.clusters) || state.clusters.length === 0 ||
        !state.clusters.every(cluster =>
            isRecord(cluster) &&
            SOLANA_CLUSTER_VALUES.has(cluster.value) &&
            typeof cluster.label === "string" &&
            typeof cluster.isSelected === "boolean"
        ) ||
        !hasUniqueValues(state.clusters, cluster => cluster.value)) {
        return false;
    }
    const selectedCount = state.clusters.filter(cluster => cluster.isSelected).length;
    return state.requiresClusterSelection ? selectedCount === 0 : selectedCount === 1;
}

function isTransactionEditor(editor) {
    if (!isRecord(editor) ||
        typeof editor.usesEIP1559 !== "boolean" ||
        typeof editor.nonce !== "string" ||
        !isOptionalString(editor.gasPriceGwei) ||
        !isOptionalString(editor.maxPriorityFeePerGasGwei) ||
        !isOptionalString(editor.maxFeePerGasGwei) ||
        !isOptionalString(editor.suggestedGasPriceGwei) ||
        !isOptionalString(editor.suggestedMaxPriorityFeePerGasGwei) ||
        !isOptionalString(editor.suggestedMaxFeePerGasGwei)) {
        return false;
    }
    return editor.usesEIP1559
        ? typeof editor.maxPriorityFeePerGasGwei === "string" &&
            typeof editor.maxFeePerGasGwei === "string"
        : typeof editor.gasPriceGwei === "string";
}

function isTransactionState(state) {
    return isDisplayAccount(state.account) &&
        typeof state.networkName === "string" &&
        Array.isArray(state.feeLines) &&
        state.feeLines.every(line => typeof line === "string") &&
        TRANSACTION_PHASES.has(state.phase) &&
        typeof state.canApprove === "boolean" &&
        typeof state.canEdit === "boolean" &&
        typeof state.transactionMutationAllowed === "boolean" &&
        isOptionalString(state.balance) &&
        isOptionalString(state.valueLine) &&
        isOptionalString(state.dataInterpretation) &&
        (typeof state.editorRequestToken === "undefined" ||
            Number.isSafeInteger(state.editorRequestToken)) &&
        isRecord(state.slider) &&
        typeof state.slider.visible === "boolean" &&
        typeof state.slider.enabled === "boolean" &&
        typeof state.slider.position === "number" &&
        Number.isFinite(state.slider.position) &&
        typeof state.slider.maximum === "number" &&
        Number.isFinite(state.slider.maximum) &&
        isTransactionEditor(state.editor);
}

function isRenderableApprovalState(state, request) {
    if (!isApprovalStateEnvelope(state, request) ||
        !hasValidOptionalApprovalFields(state)) {
        return false;
    }
    if (typeof state.kind === "undefined") {
        if (isCompactApprovalErrorState(state) ||
            isCompactRejectableApprovalState(state)) { return true; }
        return state.state !== "review" &&
            state.state !== "error" &&
            Object.keys(state).every(key =>
                key === "id" || key === "state" || key === "host"
            );
    }
    if (!APPROVAL_KINDS.has(state.kind)) {
        return false;
    }
    if (
        typeof state.title !== "string" ||
        typeof state.host !== "string" || state.host.length === 0) {
        return false;
    }
    switch (state.kind) {
        case "selectAccount":
        case "switchAccount":
            return typeof state.alert === "undefined" && isSelectionState(state);
        case "signMessage":
            return typeof state.alert === "undefined" && isSignMessageState(state);
        case "sendTransaction":
            return isTransactionState(state);
        case "addChain":
            return typeof state.alert === "undefined" &&
                typeof state.chainName === "string" &&
                typeof state.rpcURL === "string";
    }
    return false;
}

function isCompactApprovalErrorState(state) {
    return isRecord(state) && state.state === "error" &&
        isValidRequestId(state.id) && typeof state.error === "string" &&
        (typeof state.host === "undefined" ||
            typeof state.host === "string" && state.host.length > 0) &&
        Object.keys(state).every(key =>
            key === "id" || key === "state" || key === "host" ||
                key === "error" || key === "secureSetupRequired"
        );
}

function isCompactRejectableApprovalState(state) {
    return isRecord(state) && state.state === "working" &&
        isValidRequestId(state.id) && typeof state.error === "string" &&
        state.canReject === true &&
        (typeof state.host === "undefined" ||
            typeof state.host === "string" && state.host.length > 0) &&
        Object.keys(state).every(key =>
            key === "id" || key === "state" || key === "host" ||
                key === "error" || key === "canReject"
        );
}

function shouldPollApprovalState(state) {
    return state?.state === "authenticating" ||
        state?.state === "working" &&
            !isCompactRejectableApprovalState(state);
}

// The previous request's screen stays on display until this one renders, so it keeps the overlay
// up and drops the state behind it: a click landing in that window must not reach the wallet.
function resetSelections() {
    closeAlert(false);
    approvalLifecycle.current = null;
    selectionRender.lastStateJSON = null;
    resetTransactionRefreshBackoff();
    show("working-overlay");
    document.getElementById("tx-editor").open = false;
    transactionInteraction.editorDirty = false;
    if (transactionInteraction.sliderDragging) {
        transactionInteraction.ignoreSliderUntilRelease = true;
    }
    transactionInteraction.sliderDragging = false;
    transactionInteraction.sliderRequest = null;
    transactionInteraction.sliderReviewToken = null;
    transactionInteraction.generation += 1;
    const activeCommand = transactionInteraction.activeCommand;
    if (activeCommand) {
        cancelNativeMessageTicket(activeCommand.nativeTicket);
        finishSliderCommand(activeCommand, false);
        transactionInteraction.activeCommand = null;
    }
    selectionRender.accounts = null;
    selectionRender.chainId = null;
    selectionRender.cluster = null;
}

// Clear-first, so every scheduling path converges on a single refresh chain instead of
// leaking a second timer it can no longer cancel.
function scheduleTransactionRefresh(value) {
    const request = requestFor(value);
    if (!request || !isCurrentRequest(request)) { return; }
    if (approvalLifecycle.refreshTimer) {
        clearTimeout(approvalLifecycle.refreshTimer);
    }
    approvalLifecycle.refreshTimer = setTimeout(() => {
        approvalLifecycle.refreshTimer = null;
        refreshTransactionState(request);
    }, transactionRefresh.delay);
}

function resetTransactionRefreshBackoff() {
    transactionRefresh.delay = TRANSACTION_REFRESH_INTERVAL;
}

function updateTransactionRefreshBackoff(state, unchanged) {
    if (!unchanged || !STABLE_TRANSACTION_PHASES.has(state.phase)) {
        resetTransactionRefreshBackoff();
        return;
    }
    transactionRefresh.delay = Math.min(
        transactionRefresh.delay * 2,
        TRANSACTION_REFRESH_MAX_INTERVAL
    );
}

async function approvalState(value, mode) {
    const generation = approvalLifecycle.generation;
    const payload = { mode: typeof mode === "undefined" ? "full" : mode };
    return requestState(
        "getApprovalState",
        payload,
        value,
        "approval",
        null,
        () => generation === approvalLifecycle.generation
    );
}

async function fetchAndRenderState(value) {
    stopTimers();
    const request = requestFor(value);
    if (!request || !isCurrentRequest(request)) { return; }
    const generation = approvalLifecycle.generation;
    const state = await approvalState(request);
    if (generation !== approvalLifecycle.generation) { return; }
    if (!isCurrentRequest(request)) { return; }
    if (state === NATIVE_MESSAGE_CANCELLED) { return; }
    if (!isRenderableApprovalState(state, request)) {
        failClosedApprovalState(request);
        return;
    }
    if (handleMissingState(state, request)) {
        return;
    }
    adoptState(state);
    if (state.kind === "sendTransaction" && state.state === "review") {
        resetTransactionRefreshBackoff();
        scheduleTransactionRefresh(request);
    } else if (shouldPollApprovalState(state)) {
        pollApproval(request);
    }
}

async function refreshTransactionState(value) {
    const request = requestFor(value);
    if (!request || !isCurrentRequest(request) || !approvalLifecycle.current || approvalLifecycle.current.id !== request.id) { return; }
    // A state fetched before an approve or reject describes the screen that click replaced;
    // adopting it would drop the working overlay while the wallet is still authenticating.
    const generation = approvalLifecycle.generation;
    const state = await approvalState(request);
    if (generation !== approvalLifecycle.generation) { return; }
    if (!isCurrentRequest(request)) { return; }
    if (state === NATIVE_MESSAGE_CANCELLED) { return; }
    if (!isRenderableApprovalState(state, request)) {
        failClosedApprovalState(request);
        return;
    }
    if (handleMissingState(state, request)) { return; }
    if (approvalLifecycle.current && approvalLifecycle.current.id === request.id) {
        const stateJSON = JSON.stringify(state);
        const unchanged = stateJSON === selectionRender.lastStateJSON;
        approvalLifecycle.current = state;
        // Most ticks return a state identical to the one on display, and rebuilding the DOM for
        // those wipes the user's text selection. The slider still follows the wallet so a stale
        // local value snaps back instead of silently diverging from the fee.
        if (!transactionInteraction.sliderDragging &&
            !transactionInteraction.activeCommand) {
            if (!unchanged) {
                renderState(state);
            } else if (state.slider && state.slider.visible) {
                document.getElementById("tx-slider").value = state.slider.position ?? 100;
            }
        }
        updateTransactionRefreshBackoff(state, unchanged);
    }
    if (shouldPollApprovalState(state)) {
        pollApproval(request);
        return;
    }
    if (isCurrentRequest(request) && approvalLifecycle.current &&
        approvalLifecycle.current.id === request.id && approvalLifecycle.current.state === "review") {
        scheduleTransactionRefresh(request);
    }
}

function renderState(state) {
    selectionRender.lastStateJSON = JSON.stringify(state);
    show("screen-request");
    hide("screen-idle");
    setText("request-title", state.title || "");
    setText("request-host", state.host || "");
    const favicon = document.getElementById("request-favicon");
    if (state.iconURL && favicon.src !== state.iconURL) {
        favicon.src = state.iconURL;
    }
    setHidden("request-favicon", !state.iconURL);
    document.getElementById("button-approve").textContent =
        state.state === "error" || shouldRefreshAccountSelection(state)
            ? localized("refresh", "Refresh")
            : state.primaryTitle || localized("ok", "OK");
    document.getElementById("button-reject").disabled = !canRejectApprovalState(state);

    hide("section-accounts");
    hide("section-message");
    hide("section-transaction");
    hide("section-chain");

    const isBusy = state.state === "working" && !canRejectApprovalState(state) ||
        state.state === "authenticating";
    setHidden("working-overlay", !isBusy);

    setOptionalText("request-error", "request-error", state.error);

    switch (state.kind) {
        case "selectAccount":
        case "switchAccount":
            renderAccountSelection(state);
            break;
        case "signMessage":
            renderSignMessage(state);
            break;
        case "sendTransaction":
            renderTransaction(state);
            break;
        case "addChain":
            renderAddChain(state);
            break;
    }

    updateApproveEnabled(state);
    renderAlertIfNeeded(state);

}

function canRejectApprovalState(state) {
    return state?.state === "review" ||
        isCompactRejectableApprovalState(state);
}

function renderAccountSelection(state) {
    show("section-accounts");
    reconcileAccountSelection(state);

    if (state.canSelectNetwork && state.networks) {
        show("network-row");
        const select = document.getElementById("network-select");
        const networksKey = JSON.stringify(state.networks.map(network => [
            network.chainId,
            network.name,
            network.isCustom === true,
        ]));
        if (networksKey !== selectionRender.networksKey) {
            selectionRender.networksKey = networksKey;
            select.innerHTML = "";
            for (const network of state.networks) {
                const option = document.createElement("option");
                option.value = network.chainId;
                // A dapp picks the name of a chain it adds, so the chain id is what tells a
                // dapp-added network apart from a bundled one wearing the same name.
                option.textContent = network.isCustom === true
                    ? network.name + " (" + network.chainId + ")"
                    : network.name;
                select.appendChild(option);
            }
        }
        if (selectionRender.chainId !== null) {
            select.value = selectionRender.chainId;
        }
    } else {
        hide("network-row");
    }

    setOptionalText("accounts-empty", "accounts-empty", state.emptyMessage);

    renderCheckedList("accounts-list", state.accounts || [], "account-row",
                      (row, account) => { fillAccountRow(row, account, true); },
                      isSelectedAccount,
                      toggleAccount);
}

function reconcileAccountSelection(state) {
    const availableAccounts = state.accounts || [];
    if (selectionRender.accounts === null) {
        selectionRender.accounts = availableAccounts
            .filter(account => account.isSelected)
            .map(accountIdentity);
    } else {
        selectionRender.accounts = selectionRender.accounts
            .map(selected => availableAccounts.find(account => sameAccount(selected, account)))
            .filter(account => typeof account !== "undefined")
            .map(accountIdentity);
    }

    if (!state.canSelectNetwork || !Array.isArray(state.networks)) {
        selectionRender.chainId = null;
        return;
    }
    const selectedNetwork = state.networks.find(
        network => network.chainId === selectionRender.chainId
    ) || state.networks.find(network => network.isSelected) || state.networks[0];
    selectionRender.chainId = selectedNetwork ? selectedNetwork.chainId : null;
}

function renderCheckedList(containerId, items, rowClass, fillRow, isSelected, select) {
    const container = document.getElementById(containerId);
    container.innerHTML = "";
    for (const [index, item] of items.entries()) {
        const row = document.createElement("button");
        const selected = isSelected(item);
        row.type = "button";
        row.className = rowClass;
        row.setAttribute("aria-pressed", selected ? "true" : "false");
        fillRow(row, item);
        const check = document.createElement("span");
        check.className = "account-check";
        check.textContent = selected ? "✓" : "";
        check.setAttribute("aria-hidden", "true");
        row.appendChild(check);
        row.addEventListener("click", () => {
            select(item);
            renderState(approvalLifecycle.current);
            const replacement = document.getElementById(containerId).children[index];
            if (replacement && typeof replacement.focus === "function") {
                replacement.focus();
            }
        });
        container.appendChild(row);
    }
}

function accountIdentity(account) {
    return {
        walletId: account.walletId,
        coin: account.coin,
        address: account.address,
        derivationPath: account.derivationPath
    };
}

function sameAccount(left, right) {
    return accountIdentityKey(left) === accountIdentityKey(right);
}

function isSelectedAccount(account) {
    return selectionRender.accounts.some(selected => sameAccount(selected, account));
}

function toggleAccount(account) {
    if (isSelectedAccount(account)) {
        selectionRender.accounts = selectionRender.accounts.filter(selected => !sameAccount(selected, account));
    } else {
        selectionRender.accounts = selectionRender.accounts.filter(selected => selected.coin !== account.coin);
        selectionRender.accounts.push(accountIdentity(account));
    }
}

function canApproveAccountSelection(state) {
    if (!Array.isArray(selectionRender.accounts)) {
        return false;
    }
    if (selectionRender.accounts.length === 0) {
        return state.allowsEmptySelection === true;
    }
    const selectedEthereum = selectionRender.accounts.some(account => account.coin === "ethereum");
    return !selectedEthereum || isCanonicalEthereumChainId(selectionRender.chainId);
}

function shouldRefreshAccountSelection(state) {
    return (state.kind === "selectAccount" || state.kind === "switchAccount") &&
        Array.isArray(state.accounts) && state.accounts.length === 0 &&
        state.allowsEmptySelection === false;
}

function updateApproveEnabled(state) {
    const approve = document.getElementById("button-approve");
    if (state.state === "error") {
        approve.disabled = false;
    } else if (state.state !== "review") {
        approve.disabled = true;
    } else if (state.kind === "selectAccount" || state.kind === "switchAccount") {
        approve.disabled = !shouldRefreshAccountSelection(state) &&
            !canApproveAccountSelection(state);
    } else if (state.kind === "sendTransaction") {
        approve.disabled = state.canApprove !== true;
    } else if (state.kind === "signMessage") {
        approve.disabled = state.requiresClusterSelection === true && selectionRender.cluster === null;
    } else if (state.kind === "addChain") {
        approve.disabled = false;
    } else {
        approve.disabled = true;
    }
}

function renderSignMessage(state) {
    show("section-message");
    renderAccountRow("signing-account", state.account);
    setText("message-meta", state.meta || "");
    const clusters = state.clusters || [];
    setHidden("clusters", !(clusters.length > 0));
    if (clusters.length > 0) {
        const current = clusters.find(cluster => cluster.value === selectionRender.cluster);
        if (!current) {
            const selected = clusters.find(c => c.isSelected);
            selectionRender.cluster = selected ? selected.value : null;
        }
        renderCheckedList("clusters", clusters, "cluster-row",
                          (row, cluster) => {
                              const label = document.createElement("span");
                              label.textContent = cluster.label;
                              row.appendChild(label);
                          },
                          cluster => cluster.value === selectionRender.cluster,
                          cluster => { selectionRender.cluster = cluster.value; });
    } else {
        selectionRender.cluster = null;
    }
}

function renderAccountRow(elementId, account) {
    fillAccountRow(document.getElementById(elementId), account, false);
}

function fillAccountRow(container, account, alwaysShowAddress) {
    container.innerHTML = "";
    if (!account) { return; }
    if (account.icon) {
        const icon = document.createElement("img");
        icon.className = "account-icon";
        icon.src = account.icon;
        icon.alt = "";
        icon.setAttribute("aria-hidden", "true");
        container.appendChild(icon);
    }
    const text = document.createElement("span");
    text.className = "account-text";
    const name = document.createElement("span");
    name.className = "account-name";
    name.textContent = account.name;
    text.appendChild(name);
    if (alwaysShowAddress || (account.croppedAddress && account.croppedAddress !== account.name)) {
        const address = document.createElement("span");
        address.className = "account-address";
        address.textContent = account.croppedAddress;
        text.appendChild(address);
    }
    container.appendChild(text);
}

function renderTransaction(state) {
    show("section-transaction");
    renderAccountRow("tx-account", state.account);
    setText("tx-network", state.networkName || "");
    setOptionalText("tx-balance", "tx-balance-row", state.balance);
    setOptionalText("tx-value", "tx-value-row", state.valueLine);
    const feeLines = document.getElementById("tx-fee-lines");
    feeLines.innerHTML = "";
    for (const line of state.feeLines || []) {
        const div = document.createElement("div");
        div.className = "fee-line";
        div.textContent = line;
        feeLines.appendChild(div);
    }
    if (state.phase === "preparing" || state.phase === "idle") {
        const div = document.createElement("div");
        div.className = "fee-line";
        div.textContent = localized("calculating", "Calculating...");
        feeLines.appendChild(div);
    }

    const sliderState = state.slider && state.slider.visible ? state.slider : null;
    setHidden("tx-slider-row", !sliderState);
    if (sliderState) {
        const slider = document.getElementById("tx-slider");
        const firstFeeLine = feeLines.children[0]?.textContent ||
            localized("calculating", "Calculating...");
        slider.max = sliderState.maximum || 200;
        if (!transactionInteraction.sliderDragging) {
            slider.value = sliderState.position ?? 100;
        }
        slider.disabled = sliderState.enabled !== true;
        slider.setAttribute("aria-valuetext", firstFeeLine);
    }

    setOptionalText("tx-data", "tx-data-details", state.dataInterpretation);

    const canApplyEdits = state.transactionMutationAllowed === true && state.canEdit === true;
    document.getElementById("editor-apply").disabled = !canApplyEdits;
    document.getElementById("editor-suggested").disabled = !canApplyEdits;
    const editorDetails = document.getElementById("tx-editor");
    if (state.transactionMutationAllowed !== true) {
        const request = queueTab.items[queueTab.index];
        if (request) {
            discardSliderCommands(request);
        }
        transactionInteraction.editorDirty = false;
        hide("edits-error");
        editorDetails.open = false;
        hide("tx-editor");
    } else if (state.canEdit || editorDetails.open) {
        show("tx-editor");
        // An open editor keeps whatever the user typed, but until they type it follows the fee:
        // applying fields left over from before a slider move would silently undo that move.
        if (!transactionInteraction.editorDirty) {
            populateEditor(state);
        }
        const request = queueTab.items[queueTab.index];
        const requestToken = request && request.id === state.id
            ? request.requestToken || ""
            : "";
        const editorRequestKey = typeof state.editorRequestToken === "number"
            ? requestToken + ":" + state.id + ":" + state.editorRequestToken
            : null;
        if (editorRequestKey !== null && editorRequestKey !== transactionInteraction.lastEditorRequestKey) {
            transactionInteraction.lastEditorRequestKey = editorRequestKey;
            editorDetails.open = true;
        }
    } else {
        hide("tx-editor");
    }
}

function populateEditor(state) {
    transactionInteraction.editorDirty = false;
    const editor = state.editor || {};
    if (editor.usesEIP1559) {
        show("editor-eip1559");
        hide("editor-legacy");
        document.getElementById("edit-max-priority").value = editor.maxPriorityFeePerGasGwei ?? "";
        document.getElementById("edit-max-fee").value = editor.maxFeePerGasGwei ?? "";
    } else {
        show("editor-legacy");
        hide("editor-eip1559");
        document.getElementById("edit-gas-price").value = editor.gasPriceGwei ?? "";
    }
    document.getElementById("edit-nonce").value = editor.nonce ?? "";
    const hasSuggested = editor.suggestedGasPriceGwei != null || editor.suggestedMaxFeePerGasGwei != null;
    setHidden("editor-suggested", !hasSuggested);
    hide("edits-error");
}

function renderAddChain(state) {
    show("section-chain");
    setText("chain-name", state.chainName || "");
    setText("chain-rpc", state.rpcURL || "");
}

async function approveCurrent() {
    if (!approvalLifecycle.current) { return; }
    if (approvalLifecycle.current.state === "error") {
        document.getElementById("button-approve").disabled = true;
        show("working-overlay");
        await fetchAndRenderState(queueTab.items[queueTab.index]);
        return;
    }
    if (shouldRefreshAccountSelection(approvalLifecycle.current)) {
        document.getElementById("button-approve").disabled = true;
        await fetchAndRenderState(approvalLifecycle.current.id);
        return;
    }
    const payload = {};
    if (approvalLifecycle.current.kind === "selectAccount" || approvalLifecycle.current.kind === "switchAccount") {
        if (!canApproveAccountSelection(approvalLifecycle.current)) { return; }
        payload.selectedAccounts = selectionRender.accounts;
        if (approvalLifecycle.current.canSelectNetwork &&
            isCanonicalEthereumChainId(selectionRender.chainId)) {
            payload.chainId = selectionRender.chainId;
        }
    } else if (approvalLifecycle.current.kind === "signMessage" && selectionRender.cluster) {
        payload.cluster = selectionRender.cluster;
    }
    await submitCurrentDecision("approveRequest", payload);
}

async function rejectCurrent() {
    await submitCurrentDecision("rejectRequest");
}

function canSubmitDecision(subject, state) {
    return subject === "rejectRequest"
        ? canRejectApprovalState(state)
        : state?.state === "review" && isRequestToken(state.reviewToken);
}

async function submitCurrentDecision(subject, payload) {
    const request = queueTab.items[queueTab.index];
    const initialState = approvalLifecycle.current;
    if (!request || !canSubmitDecision(subject, initialState)) { return; }
    const rerenderCurrentReview = () => {
        const currentState = approvalLifecycle.current;
        if (isCurrentRequest(request) && currentState?.state === "review") {
            renderState(currentState);
        }
    };
    if (subject === "approveRequest") {
        finishSliderDragForDecision(request);
        if (!await waitForSliderCommands(request)) { return; }
    } else {
        discardSliderCommands(request);
    }
    const state = approvalLifecycle.current;
    if (!isCurrentRequest(request) || !canSubmitDecision(subject, state)) {
        rerenderCurrentReview();
        return;
    }
    const reviewToken = subject === "approveRequest"
        ? state.reviewToken
        : undefined;
    const remainsCurrent = () => isCurrentRequest(request) &&
        canSubmitDecision(subject, approvalLifecycle.current) &&
        (subject !== "approveRequest" ||
            approvalLifecycle.current?.reviewToken === reviewToken);
    show("working-overlay");
    let decisionPayload = payload;
    if (subject === "approveRequest") {
        decisionPayload = {...(isRecord(payload) ? payload : {})};
        delete decisionPayload.revisions;
        delete decisionPayload.password;
    }
    approvalLifecycle.generation += 1;
    stopTimers();
    const ticket = scheduleNativeMessage(
        "action",
        subject,
        request.id,
        decisionPayload,
        request.requestToken,
        {isValid: remainsCurrent, reviewToken, approvalRequest: request}
    );
    const outcome = await ticket.result;
    if (outcome.status === "cancelled") {
        rerenderCurrentReview();
        return;
    }
    if (!isCurrentRequest(request)) { return; }
    if (outcome.status !== "response" || !isRecord(outcome.response)) {
        failClosedApprovalState(request);
        return;
    }
    pollApproval(request);
}

function pollApproval(value) {
    const request = requestFor(value);
    if (!request || !isCurrentRequest(request)) { return; }
    stopTimers();
    approvalLifecycle.pollTimer = setTimeout(async () => {
        approvalLifecycle.pollTimer = null;
        const generation = approvalLifecycle.generation;
        const state = await approvalState(request, "poll");
        if (!isCurrentRequest(request)) {
            return;
        }
        // A mutation landing mid-fetch supersedes this state, but the wallet still owes the
        // request an outcome — the poll keeps following instead of stranding the overlay.
        if (generation !== approvalLifecycle.generation) {
            pollApproval(request);
            return;
        }
        if (state === NATIVE_MESSAGE_CANCELLED) { return; }
        if (!isRenderableApprovalState(state, request)) {
            failClosedApprovalState(request);
            return;
        }
        if (handleMissingState(state, request)) {
            return;
        }
        if (state.state === "error") {
            hide("working-overlay");
            adoptState(state);
            return;
        }
        if (state.state === "review") {
            hide("working-overlay");
            adoptState(state);
            if (state.kind === "sendTransaction") {
                resetTransactionRefreshBackoff();
                scheduleTransactionRefresh(request);
            }
        } else if (canRejectApprovalState(state)) {
            hide("working-overlay");
            const retainedError = approvalLifecycle.current?.state === "working" &&
                approvalLifecycle.current.kind === undefined &&
                approvalLifecycle.current.canReject === true &&
                typeof approvalLifecycle.current.error === "string"
                ? approvalLifecycle.current.error
                : null;
            adoptState(retainedError === null ? state : { ...state, error: retainedError });
            if (shouldPollApprovalState(state)) {
                pollApproval(request);
            }
        } else {
            pollApproval(request);
        }
    }, APPROVAL_POLL_INTERVAL);
}

async function reconcileMissingRequest(value) {
    const request = requestFor(value);
    if (!request || !isCurrentRequest(request) || sameRequest(approvalLifecycle.completion, request)) { return; }
    stopTimers();
    closeAlert(false);
    approvalLifecycle.completion = request;
    try {
        await closeIfNothingIsLeft();
    } finally {
        if (sameRequest(approvalLifecycle.completion, request)) {
            approvalLifecycle.completion = null;
        }
    }
}

async function applyCompletedResponse(request) {
    let pending;
    try {
        pending = browser.runtime.sendMessage({
            subject: "applyCompletedResponse",
            id: request.id,
            host: request.host,
            configurationKey: request.configurationKey,
            requestToken: request.requestToken,
            revisions: request.revisions,
            workflowVersion: WORKFLOW_VERSION,
        });
    } catch {
        return "failure";
    }
    const outcome = await settleExtensionMessage(pending);
    if (outcome.status !== "response") { return "failure"; }
    if (hasExactKeys(outcome.response, ["applied"]) &&
        outcome.response.applied === true) {
        return "applied";
    }
    if (hasExactKeys(outcome.response, ["id", "missing"]) &&
        outcome.response.id === request.id && outcome.response.missing === true) {
        return "missing";
    }
    return "failure";
}

// The queue is a snapshot taken when the popup opened, so it is asked again before closing:
// a request that arrived in the meantime gets shown instead of being left behind. A fetch
// failure keeps the popup open too — an unreachable wallet does not mean the queue drained.
async function closeIfNothingIsLeft() {
    stopTimers();
    const requests = await refreshQueue();
    if (requests !== null && requests.length === 0 &&
        !shouldShowUpdateRecovery() &&
        queueTab.snapshotStatus === "empty" &&
        queueTab.refreshInFlight === null &&
        queueTab.refreshRequested === false &&
        queueTab.refreshTimer === null) {
        window.close();
    }
}

// Both slots get cleared: an approve landing mid-refresh can leave a poll and a refresh
// outstanding at once, and whichever finishes the request has to cancel the other.
function stopTimers() {
    if (approvalLifecycle.pollTimer) {
        clearTimeout(approvalLifecycle.pollTimer);
        approvalLifecycle.pollTimer = null;
    }
    if (approvalLifecycle.refreshTimer) {
        clearTimeout(approvalLifecycle.refreshTimer);
        approvalLifecycle.refreshTimer = null;
    }
}

async function requestState(
    subject,
    payload,
    value,
    nativeCallKind = "approval",
    ticketOwner = null,
    remainsValid = null,
    reviewToken
) {
    const request = requestFor(value);
    if (!request || !isCurrentRequest(request)) { return null; }
    const options = {
        isValid: () => isCurrentRequest(request) && (!remainsValid || remainsValid()),
    };
    if (typeof reviewToken !== "undefined") {
        options.reviewToken = reviewToken;
    }
    const ticket = scheduleNativeMessage(
        nativeCallKind,
        subject,
        request.id,
        payload,
        request.requestToken,
        options
    );
    if (ticketOwner) {
        ticketOwner.nativeTicket = ticket;
    }
    const outcome = await ticket.result;
    if (outcome.status === "cancelled") { return NATIVE_MESSAGE_CANCELLED; }
    return outcome.status === "response" ? outcome.response : null;
}

// Every user-initiated mutation advances the generation, so a state fetched before it — a
// refresh tick or an earlier mutation still in flight — reports null instead of landing on
// top of the newer interaction and resurrecting the screen it replaced.
async function mutateState(subject, payload, value, reviewToken) {
    const request = requestFor(value);
    if (!request || !isCurrentRequest(request)) { return null; }
    const isRichMutation = subject !== "setTransactionSpeed";
    if (isRichMutation && sameRequest(approvalLifecycle.mutation?.request, request)) {
        return null;
    }
    const mutation = { request: request, subject: subject };
    if (isRichMutation) {
        approvalLifecycle.mutation = mutation;
    }
    try {
        if (isRichMutation && !await waitForSliderCommands(request)) { return null; }
        if (!isCurrentRequest(request)) { return null; }
        if (isRichMutation && approvalLifecycle.mutation !== mutation) {
            return null;
        }
        if (subject === "applyTransactionEdits" &&
            approvalLifecycle.current?.canEdit !== true) { return null; }
        approvalLifecycle.generation += 1;
        resetTransactionRefreshBackoff();
        const generation = approvalLifecycle.generation;
        const ticketOwner = isRichMutation ? mutation : transactionInteraction.activeCommand;
        const state = await requestState(
            subject,
            payload,
            request,
            "mutation",
            ticketOwner,
            () => generation === approvalLifecycle.generation &&
                (typeof reviewToken === "undefined" ||
                    approvalLifecycle.current?.reviewToken === reviewToken),
            reviewToken
        );
        if (generation !== approvalLifecycle.generation) { return null; }
        if (!isCurrentRequest(request)) { return null; }
        if (state === NATIVE_MESSAGE_CANCELLED) { return null; }
        if (!isRenderableApprovalState(state, request)) {
            if ((subject === "resolveApprovalAlert" ||
                subject === "setTransactionSpeed") && isRecord(state) &&
                state.status === "ignored" && Object.keys(state).length === 1) {
                return null;
            }
            failClosedApprovalState(request);
            return null;
        }
        if (handleMissingState(state, request)) { return null; }
        return state;
    } finally {
        if (approvalLifecycle.mutation === mutation) {
            approvalLifecycle.mutation = null;
        }
    }
}

function handleMissingState(state, value) {
    if (!state || state.state !== "missing") { return false; }
    const request = requestFor(value);
    if (!request || !isCurrentRequest(request)) { return true; }
    void reconcileMissingRequest(request);
    return true;
}

function failClosedApprovalState(request) {
    if (!request || !isCurrentRequest(request)) { return; }
    approvalLifecycle.generation += 1;
    const previous = approvalLifecycle.current || {};
    selectionRender.lastStateJSON = null;
    resetTransactionRefreshBackoff();
    stopTimers();
    closeAlert(false);
    document.getElementById("tx-editor").open = false;
    transactionInteraction.editorDirty = false;
    hide("edits-error");
    document.getElementById("button-approve").disabled = true;
    approvalLifecycle.current = {
        id: request.id,
        state: "error",
        ...(typeof previous.host === "string" && previous.host.length > 0
            ? {host: previous.host}
            : {}),
        error: localized("failedToLoad", "Failed to load"),
    };
    renderState(approvalLifecycle.current);
}

// A mutation can strand the review screen: the tick it superseded was dropped without
// rescheduling, and its own response may have been superseded or failed in turn. Whatever
// the outcome, the refresh loop keeps following the wallet — unless an approval poll owns
// the request now.
function keepFollowingTransaction() {
    if (approvalLifecycle.pollTimer) { return; }
    if (approvalLifecycle.current && approvalLifecycle.current.kind === "sendTransaction" && approvalLifecycle.current.state === "review") {
        scheduleTransactionRefresh(approvalLifecycle.current.id);
    }
}

function adoptState(state) {
    if (!state || !state.state) { return; }
    approvalLifecycle.current = state;
    renderState(state);
}

async function sendSliderEvent(
    interaction,
    value,
    request,
    commandGeneration = transactionInteraction.generation,
    reviewToken = approvalLifecycle.current?.reviewToken
) {
    const capturedRequest = requestFor(request);
    if (!capturedRequest || !isCurrentRequest(capturedRequest)) { return false; }
    let refreshed = false;
    const refreshAuthoritativeState = async () => {
        if (!refreshed && commandGeneration === transactionInteraction.generation &&
            isCurrentRequest(capturedRequest)) {
            refreshed = true;
            await fetchAndRenderState(capturedRequest);
        }
        return false;
    };
    if (!isRequestToken(reviewToken) ||
        approvalLifecycle.current?.reviewToken !== reviewToken) {
        return await refreshAuthoritativeState();
    }
    const state = await mutateState(
        "setTransactionSpeed",
        {value, interaction},
        capturedRequest,
        reviewToken
    );
    if (commandGeneration !== transactionInteraction.generation ||
        !isCurrentRequest(capturedRequest)) {
        return false;
    }
    if (!state) { return await refreshAuthoritativeState(); }
    adoptState(state);
    keepFollowingTransaction();
    return true;
}

function beginSliderInteraction(
    request,
    reviewToken = approvalLifecycle.current?.reviewToken
) {
    const capturedRequest = requestFor(request);
    if (transactionInteraction.activeCommand ||
        transactionInteraction.sliderDragging ||
        !capturedRequest || !isCurrentRequest(capturedRequest) ||
        !isRequestToken(reviewToken)) {
        return false;
    }
    transactionInteraction.ignoreSliderUntilRelease = false;
    transactionInteraction.sliderDragging = true;
    transactionInteraction.sliderRequest = capturedRequest;
    transactionInteraction.sliderReviewToken = reviewToken;
    return true;
}

function startSliderCommand(
    interaction,
    value,
    request,
    reviewToken = approvalLifecycle.current?.reviewToken
) {
    const capturedRequest = requestFor(request);
    if (!capturedRequest || !isCurrentRequest(capturedRequest) ||
        !isRequestToken(reviewToken) || transactionInteraction.activeCommand) {
        return null;
    }
    let resolveCompletion;
    const command = {
        commandGeneration: transactionInteraction.generation,
        completion: new Promise(resolve => { resolveCompletion = resolve; }),
        interaction: interaction,
        request: capturedRequest,
        reviewToken: reviewToken,
        resolveCompletion: null,
        value: value,
    };
    command.resolveCompletion = resolveCompletion;
    transactionInteraction.activeCommand = command;
    document.getElementById("tx-slider").disabled = true;
    void (async () => {
        let succeeded = false;
        try {
            succeeded = await sendSliderEvent(
                command.interaction,
                command.value,
                command.request,
                command.commandGeneration,
                command.reviewToken
            );
        } finally {
            if (transactionInteraction.activeCommand === command) {
                transactionInteraction.activeCommand = null;
            }
            finishSliderCommand(command, succeeded);
        }
    })();
    return command.completion;
}

function finishSliderCommand(command, succeeded) {
    if (!command?.resolveCompletion) { return; }
    const resolve = command.resolveCompletion;
    command.resolveCompletion = null;
    resolve(succeeded);
}

async function waitForSliderCommands(request) {
    const generation = transactionInteraction.generation;
    if (transactionInteraction.sliderDragging &&
        sameRequest(transactionInteraction.sliderRequest, request)) {
        return false;
    }
    const command = transactionInteraction.activeCommand;
    if (!command) { return true; }
    if (command.commandGeneration !== generation ||
        !sameRequest(command.request, request)) { return false; }
    const succeeded = await command.completion;
    return succeeded === true && generation === transactionInteraction.generation &&
        isCurrentRequest(request);
}

function discardSliderCommands(request) {
    transactionInteraction.generation += 1;
    const command = transactionInteraction.activeCommand;
    if (sameRequest(command?.request, request)) {
        cancelNativeMessageTicket(command.nativeTicket);
        finishSliderCommand(command, false);
        transactionInteraction.activeCommand = null;
    }
    if (sameRequest(transactionInteraction.sliderRequest, request)) {
        transactionInteraction.ignoreSliderUntilRelease = true;
        transactionInteraction.sliderDragging = false;
        transactionInteraction.sliderRequest = null;
        transactionInteraction.sliderReviewToken = null;
    }
}

function finishSliderInteraction(interaction, request) {
    if (!transactionInteraction.sliderDragging ||
        (request && !sameRequest(transactionInteraction.sliderRequest, request))) {
        return null;
    }
    const capturedRequest = transactionInteraction.sliderRequest;
    const value = Number(document.getElementById("tx-slider").value);
    const reviewToken = transactionInteraction.sliderReviewToken;
    transactionInteraction.sliderDragging = false;
    transactionInteraction.sliderRequest = null;
    transactionInteraction.sliderReviewToken = null;
    return startSliderCommand(
        interaction,
        value,
        capturedRequest,
        reviewToken
    );
}

function finishSliderDragForDecision(request) {
    if (!transactionInteraction.sliderDragging ||
        !sameRequest(transactionInteraction.sliderRequest, request)) { return; }
    transactionInteraction.ignoreSliderUntilRelease = true;
    finishSliderInteraction("ended", request);
}

async function applyEdits() {
    if (approvalLifecycle.current?.canEdit !== true ||
        approvalLifecycle.current.transactionMutationAllowed !== true) { return; }
    const editor = (approvalLifecycle.current.editor || {});
    const payload = {
        mode: "custom",
        nonce: document.getElementById("edit-nonce").value,
    };
    if (editor.usesEIP1559) {
        payload.maxPriorityFeePerGasGwei = document.getElementById("edit-max-priority").value;
        payload.maxFeePerGasGwei = document.getElementById("edit-max-fee").value;
    } else {
        payload.gasPriceGwei = document.getElementById("edit-gas-price").value;
    }
    handleTransactionEditResult(await mutateState("applyTransactionEdits", payload));
}

async function applySuggested() {
    if (approvalLifecycle.current?.canEdit !== true ||
        approvalLifecycle.current.transactionMutationAllowed !== true) { return; }
    handleTransactionEditResult(await mutateState(
        "applyTransactionEdits",
        { mode: "suggested" }
    ));
}

function handleTransactionEditResult(state) {
    if (state && state.editsError) {
        show("edits-error");
    } else {
        closeEditorAndAdopt(state);
    }
    keepFollowingTransaction();
}

function closeEditorAndAdopt(state) {
    if (!state || !state.state) { return; }
    transactionInteraction.editorDirty = false;
    hide("edits-error");
    document.getElementById("tx-editor").open = false;
    adoptState(state);
}

function renderAlertIfNeeded(state) {
    if (!state.alert) {
        closeAlert(state.state === "review");
        return;
    }
    const title = state.alert.title || "";
    const message = state.alert.message || "";
    const actions = state.alert.actions;
    const alertKey = JSON.stringify([
        title,
        message,
        actions.map(action => [action.title, action.action]),
    ]);
    const overlay = document.getElementById("alert-overlay");
    if (selectionRender.alertKey === alertKey && !overlay.classList.contains("hidden")) {
        return;
    }
    if (selectionRender.alertKey === null) {
        const activeElement = document.activeElement;
        selectionRender.alertReturnFocus = activeElement && typeof activeElement.focus === "function"
            ? activeElement
            : null;
    }
    selectionRender.alertKey = alertKey;
    setText("alert-title", title);
    setText("alert-message", message);
    const buttons = document.getElementById("alert-buttons");
    buttons.innerHTML = "";
    for (const action of actions) {
        const button = document.createElement("button");
        button.type = "button";
        button.className = "button primary";
        button.textContent = action.title;
        button.addEventListener("click", async () => {
            const reviewToken = approvalLifecycle.current?.reviewToken;
            const currentAlert = approvalLifecycle.current?.alert;
            if (!isRequestToken(reviewToken) || !currentAlert ||
                !currentAlert.actions.some(currentAction =>
                    currentAction.action === action.action &&
                    currentAction.title === action.title
                )) {
                return;
            }
            const state = await mutateState("resolveApprovalAlert", {
                action: action.action,
            }, undefined, reviewToken);
            if (approvalLifecycle.current?.reviewToken !== reviewToken) { return; }
            adoptState(state);
            keepFollowingTransaction();
        });
        buttons.appendChild(button);
    }
    document.getElementById("screen-request").inert = true;
    show("alert-overlay");
    const focusTarget = buttons.children[0] || document.getElementById("alert-box");
    focusTarget.focus();
}

async function switchAccountFromIdle() {
    const button = document.getElementById("idle-switch-account");
    const tab = queueTab.activeTab;
    if (button.disabled || !tab || currentPrivateBrowsing()) { return; }
    button.disabled = true;
    const message = {
        configurationKey: tab.configurationKey,
        subject: BigWalletBridgeWire.MANUAL_SWITCH_INTENT_SUBJECT,
        workflowVersion: WORKFLOW_VERSION,
    };
    let pending;
    try {
        pending = browser.tabs.sendMessage(tab.id, message);
    } catch {
        pending = Promise.reject();
    }
    const outcome = await settleExtensionMessage(
        pending,
        MANUAL_SWITCH_TIMEOUT
    );
    const response = outcome.status === "response" ? outcome.response : null;
    if (outcome.status === "failure") {
        queueTab.contentScriptUnavailableTab = tab;
    } else if (outcome.status === "response" &&
        sameTab(queueTab.contentScriptUnavailableTab, tab)) {
        queueTab.contentScriptUnavailableTab = null;
    }
    const id = response?.id;
    const valid = BigWalletBridgeWire.isManualSwitchInFlightStatus(
        response,
        tab.configurationKey
    ) || (Number.isSafeInteger(id) &&
        BigWalletBridgeWire.isManualSwitchAcknowledgement(
            response,
            id,
            tab.configurationKey
        )) || (Number.isSafeInteger(id) &&
        BigWalletBridgeWire.isManualSwitchTerminalResponse(response, id));
    if (!valid) {
        setText("idle-connection", localized("failedToLoad", "Failed to load"));
        button.disabled = false;
        renderIdleSwitchControls(false);
        return;
    }
    hide("screen-idle");
    show("screen-loading");
    await refreshQueue();
}

async function refreshIdleStatus() {
    const tab = shouldShowUpdateRecovery()
        ? queueTab.updateRecoveryTab
        : null;
    if (!tab) {
        hide("screen-idle");
        show("screen-loading");
        await refreshQueue();
        return;
    }
    const button = document.getElementById("idle-check-status");
    if (button.disabled || !Number.isSafeInteger(tab.id)) { return; }
    button.disabled = true;
    const refreshGeneration = queueTab.refreshGeneration;
    const currentTab = await currentActiveTab();
    const sameCurrentTab = sameUpdateRecoveryTab(currentTab, tab);
    const currentRecoveryTab = sameCurrentTab
        ? await updateRecoveryTabFor(currentTab)
        : null;
    if (refreshGeneration !== queueTab.refreshGeneration ||
        queueTab.snapshotStatus !== "empty" || queueTab.items.length !== 0 ||
        queueTab.refreshRequested || queueTab.refreshInFlight !== null ||
        queueTab.refreshTimer !== null) {
        button.disabled = false;
        hide("screen-idle");
        show("screen-loading");
        await refreshQueue();
        return;
    }
    if (!sameCurrentTab || !sameUpdateRecoveryTab(currentRecoveryTab, tab)) {
        queueTab.activeTab = currentTab;
        queueTab.updateRecoveryTab = null;
        button.disabled = false;
        hide("screen-idle");
        show("screen-loading");
        await refreshQueue();
        return;
    }
    let pendingReload;
    let reloadStarted = false;
    try {
        pendingReload = browser.tabs.reload(currentTab.id);
        reloadStarted = true;
    } catch {}
    const outcome = reloadStarted
        ? await settleExtensionMessage(pendingReload)
        : {status: "failure"};
    if (outcome.status === "response") {
        window.close();
        return;
    }
    button.disabled = false;
    renderIdleSwitchControls(false);
    setHidden("idle-check-status", false);
    setText("idle-connection", localized("failedToLoad", "Failed to load"));
}

function releaseOpenAppCall(call) {
    if (unresolvedOpenAppCall !== call) { return; }
    unresolvedOpenAppCall = null;
    document.getElementById("idle-open-app").disabled = false;
}

function getOpenAppCall() {
    if (unresolvedOpenAppCall !== null) {
        return unresolvedOpenAppCall;
    }
    const call = {
        id: genId(),
        result: null,
    };
    const ticket = scheduleNativeMessage(
        "app",
        "openApp",
        call.id,
        undefined,
        undefined
    );
    call.result = ticket.result;
    unresolvedOpenAppCall = call;
    void call.result.then(
        () => releaseOpenAppCall(call),
        () => releaseOpenAppCall(call)
    );
    return call;
}

async function openBigWallet() {
    const button = document.getElementById("idle-open-app");
    if (button.disabled) { return; }
    button.disabled = true;
    try {
        const call = getOpenAppCall();
        const outcome = await call.result;
        const response = outcome.status === "response" ? outcome.response : null;
        if (!isRecord(response) || response.id !== call.id || response.opened !== true) {
            throw new Error("Failed to open Big Wallet");
        }
        window.close();
    } catch {
        setText(
            "idle-connection",
            localized("somethingWentWrong", "Something went wrong")
        );
        button.disabled = unresolvedOpenAppCall !== null;
    }
}

document.addEventListener("DOMContentLoaded", () => {
    queueTab.domReady = true;
    browser.runtime.onMessage.addListener(handlePopupRuntimeMessage);
    document.getElementById("button-approve").addEventListener("click", approveCurrent);
    document.getElementById("button-reject").addEventListener("click", rejectCurrent);
    document.getElementById("idle-open-app").addEventListener("click", openBigWallet);
    document.getElementById("idle-switch-account").addEventListener("click", switchAccountFromIdle);
    document.getElementById("idle-check-status").addEventListener("click", refreshIdleStatus);
    document.getElementById("editor-apply").addEventListener("click", applyEdits);
    document.getElementById("editor-suggested").addEventListener("click", applySuggested);
    document.getElementById("network-select").addEventListener("change", () => {
        selectionRender.chainId = document.getElementById("network-select").value;
    });
    for (const fieldId of ["edit-gas-price", "edit-max-priority", "edit-max-fee", "edit-nonce"]) {
        document.getElementById(fieldId).addEventListener("input", () => { transactionInteraction.editorDirty = true; });
    }

    const slider = document.getElementById("tx-slider");
    slider.addEventListener("pointerdown", () => {
        beginSliderInteraction(queueTab.items[queueTab.index]);
    });
    slider.addEventListener("input", () => {
        if (transactionInteraction.ignoreSliderUntilRelease) { return; }
        if (!transactionInteraction.sliderDragging) {
            beginSliderInteraction(queueTab.items[queueTab.index]);
        }
    });
    const endDrag = interaction => {
        if (transactionInteraction.ignoreSliderUntilRelease) {
            transactionInteraction.ignoreSliderUntilRelease = false;
            transactionInteraction.sliderReviewToken = null;
            return;
        }
        finishSliderInteraction(interaction);
    };
    slider.addEventListener("pointerup", () => { endDrag("ended"); });
    slider.addEventListener("pointercancel", () => {
        endDrag("cancelled");
    });
    slider.addEventListener("change", () => { endDrag("ended"); });

    boot();
});
