
// ∅ 2026 lil org

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
const STABLE_TRANSACTION_PHASES = new Set([
    "ready",
    "failed",
    "reviewingFees",
    "finished",
]);
const TRANSACTION_EDITOR_FIELDS = {
    nonce: "edit-nonce",
    gasPriceGwei: "edit-gas-price",
    maxPriorityFeePerGasGwei: "edit-max-priority",
    maxFeePerGasGwei: "edit-max-fee",
};
var configurationIdentityForURL = BigWalletBridgeWire.configurationIdentityForURL;
var genId = BigWalletBridgeWire.genId;
var genPrivateToken = BigWalletBridgeWire.genPrivateToken;
var hasExactKeys = BigWalletBridgeWire.hasExactKeys;
var isCanonicalEthereumChainId = BigWalletBridgeWire.isCanonicalEthereumChainId;
var isRequestToken = BigWalletBridgeWire.isRequestToken;
var isPendingRequestAvailable = BigWalletBridgeWire.isPendingRequestAvailable;
var isRecord = BigWalletBridgeWire.isRecord;
var isValidRequestId = BigWalletBridgeWire.isValidRequestId;
var withTimeout = BigWalletBridgeWire.withTimeout;

function canonicalJSONString(value) {
    return JSON.stringify(value, (_, item) => isRecord(item)
        ? Object.fromEntries(Object.keys(item).sort().map(key => [key, item[key]]))
        : item);
}

function transactionEditorValues(editor) {
    return {
        nonce: editor.nonce ?? "",
        ...(editor.usesEIP1559 ? {
            maxPriorityFeePerGasGwei: editor.maxPriorityFeePerGasGwei ?? "",
            maxFeePerGasGwei: editor.maxFeePerGasGwei ?? "",
        } : {gasPriceGwei: editor.gasPriceGwei ?? ""}),
    };
}

let popupQueue = null;
let popupStrings = {};
let ignoreSliderUntilRelease = false;

class PopupQueueController {
    constructor() {
        this.tab = {
            activeTab: null,
            privateBrowsing: extensionPrivateBrowsing(),
            recoveryTab: null,
        };
        this.revision = 0;
        this.snapshot = {kind: "unknown", revision: -1};
        this.presentation = {kind: "booting"};
        this.refresh = {kind: "idle"};
    }

    get currentRequest() {
        return this.presentation.kind === "review" || this.presentation.kind === "reconciling"
            ? this.presentation.controller : null;
    }

    get privateBrowsing() {
        return this.tab.activeTab?.incognito ?? this.tab.privateBrowsing;
    }

    get isFresh() { return this.snapshot.revision === this.revision; }

    get isEmpty() {
        return this.isFresh && this.snapshot.kind === "ready" && this.snapshot.requests.length === 0;
    }

    get canRefresh() {
        return !["booting", "review", "closed"].includes(this.presentation.kind);
    }

    get showsUpdateRecovery() { return this.tab.recoveryTab !== null && this.isEmpty; }

    get canSwitchAccount() {
        return this.presentation.kind === "idle" && this.presentation.operation === null &&
            !this.privateBrowsing && this.tab.activeTab !== null &&
            this.tab.recoveryTab === null && this.isEmpty && this.refresh.kind === "idle";
    }

    async boot() {
        try {
            Object.assign(this.tab, await currentActiveTab());
            this.tab.recoveryTab = await readUpdateRecoveryFlag()
                ? await updateRecoveryTabFor(this.tab.activeTab) : null;
        } finally {
            this.presentation = {kind: "loading"};
        }
        await this.refreshQueue();
    }

    invalidate() {
        this.revision += 1;
        document.getElementById("idle-switch-account").disabled = true;
        this.scheduleRefresh();
    }

    scheduleRefresh() {
        if (this.isFresh || !this.canRefresh || this.refresh.kind !== "idle") { return; }
        const scheduled = {kind: "scheduled", timer: null};
        scheduled.timer = setTimeout(() => {
            if (this.refresh !== scheduled) { return; }
            this.refresh = {kind: "idle"};
            if (!this.isFresh && this.canRefresh) { void this.refreshQueue(); }
        }, 0);
        this.refresh = scheduled;
    }

    refreshQueue() {
        if (this.refresh.kind === "running") { return this.refresh.promise; }
        if (!this.canRefresh) { return Promise.resolve(null); }
        if (this.refresh.kind === "scheduled") { clearTimeout(this.refresh.timer); }
        if (this.isFresh) { this.revision += 1; }
        document.getElementById("idle-switch-account").disabled = true;
        const flight = {kind: "running", promise: null};
        this.refresh = flight;
        flight.promise = (async () => {
            try {
                while (this.canRefresh) {
                    const revision = this.revision;
                    const response = await fetchPendingResponse();
                    if (revision !== this.revision) { continue; }
                    if (!this.canRefresh) { return null; }
                    this.snapshot = response
                        ? {kind: "ready", revision, requests: response.requests}
                        : {kind: "failed", revision};
                    this.presentSnapshot();
                    return this.snapshot;
                }
                return null;
            } finally {
                if (this.refresh === flight) { this.refresh = {kind: "idle"}; }
                if (this.presentation.kind === "idle") { this.renderIdleControls(); }
                this.scheduleRefresh();
            }
        })();
        return flight.promise;
    }

    presentSnapshot() {
        this.currentRequest?.dispose();
        hide("screen-loading");
        const requests = this.snapshot.kind === "ready" ? this.snapshot.requests : null;
        if (requests) { setPendingRequestBadge(requests.length); }
        if (!requests || requests.length === 0) {
            this.presentation = {kind: "idle", token: {}, operation: null};
            void this.renderIdle();
            return;
        }
        const controller = new PopupRequestController(this, requests[0]);
        this.presentation = {kind: "review", controller};
        setHidden("queue-indicator", requests.length <= 1);
        if (requests.length > 1) {
            setText("queue-indicator", formatted(localized("queuePosition", "%1$@ of %2$@"), "1", String(requests.length)));
        }
        hide("screen-idle");
        void controller.start();
    }

    async reconcile(controller) {
        if (this.currentRequest !== controller) { return; }
        this.presentation = {kind: "reconciling", controller};
        const snapshot = await this.refreshQueue();
        if (snapshot !== null && this.snapshot === snapshot && this.isEmpty &&
            !this.showsUpdateRecovery && this.refresh.kind === "idle" &&
            this.presentation.kind === "idle" && this.presentation.operation === null) {
            this.presentation = {kind: "closed"};
            window.close();
        }
    }

    ownsIdle(token, tab, operation) {
        return this.presentation.kind === "idle" && this.presentation.token === token &&
            sameTab(this.tab.activeTab, tab) &&
            (typeof operation === "undefined" || this.presentation.operation === operation);
    }

    renderIdleControls() {
        const canSwitch = this.canSwitchAccount;
        setHidden("idle-switch-account", !canSwitch);
        document.getElementById("idle-switch-account").disabled = !canSwitch;
        setHidden("idle-check-status", this.snapshot.kind !== "failed" && !this.showsUpdateRecovery);
        document.getElementById("idle-check-status").disabled = this.presentation.operation !== null;
        hide("idle-pending-spinner");
    }

    async renderIdle() {
        const {token} = this.presentation;
        const tab = this.tab.activeTab;
        hide("screen-request");
        hide("working-overlay");
        show("screen-idle");
        this.renderIdleControls();
        setText("idle-host", tab ? (tab.host || tab.configurationKey) : "");
        if (this.snapshot.kind === "failed" || this.showsUpdateRecovery) {
            setText("idle-connection", localized("failedToLoad", "Failed to load"));
            return;
        }
        if (!tab) {
            setText("idle-connection", localized("noActivePage", "No active page"));
            return;
        }
        if (this.privateBrowsing) {
            setText("idle-connection", localized("privateBrowsingUnsupported", "Big Wallet requests are unavailable in Private Browsing."));
            return;
        }
        const configuration = await readLatestConfiguration(tab);
        if (!this.ownsIdle(token, tab)) { return; }
        let connectionText = localized("failedToLoad", "Failed to load");
        if (configuration) {
            const lines = [];
            if (configuration.ethereum?.address) { lines.push(configuration.ethereum.address); }
            if (configuration.solana) { lines.push(configuration.solana.publicKey); }
            connectionText = lines.length > 0 ? lines.join("\n") : localized("notConnected", "Not connected");
        }
        setText("idle-connection", connectionText);
    }

    async switchAccountFromIdle() {
        if (!this.canSwitchAccount) { return; }
        const tab = this.tab.activeTab;
        this.presentation.token = {};
        const {token} = this.presentation;
        const operation = {kind: "switch"};
        this.presentation.operation = operation;
        document.getElementById("idle-switch-account").disabled = true;
        let pending;
        try {
            pending = browser.tabs.sendMessage(tab.id, {
                configurationKey: tab.configurationKey,
                subject: BigWalletBridgeWire.MANUAL_SWITCH_INTENT_SUBJECT,
                workflowVersion: WORKFLOW_VERSION,
            });
        } catch { pending = Promise.reject(); }
        const outcome = await settleExtensionMessage(pending, MANUAL_SWITCH_TIMEOUT);
        if (!this.ownsIdle(token, tab, operation)) {
            this.invalidate();
            return;
        }
        const response = outcome.status === "response" ? outcome.response : null;
        const id = response?.id;
        const valid = Number.isSafeInteger(id) && (
            BigWalletBridgeWire.isManualSwitchAcknowledgement(response, id, tab.configurationKey) ||
            BigWalletBridgeWire.isManualSwitchTerminalResponse(response, id));
        const terminal = valid ? BigWalletBridgeWire.decodeNativeResponse(response, id) : null;
        if (!valid || terminal?.kind === "error") {
            this.presentation.operation = null;
            setText("idle-connection", terminal?.error.message || localized("failedToLoad", "Failed to load"));
            this.renderIdleControls();
            return;
        }
        this.showLoading();
        await this.refreshQueue();
    }

    showLoading() {
        this.presentation = {kind: "loading"};
        hide("screen-idle");
        show("screen-loading");
    }

    async refreshIdleStatus() {
        if (this.presentation.kind !== "idle" || this.presentation.operation !== null) { return; }
        const recoveryTab = this.showsUpdateRecovery ? this.tab.recoveryTab : null;
        if (!recoveryTab) {
            this.showLoading();
            await this.refreshQueue();
            return;
        }
        if (!Number.isSafeInteger(recoveryTab.id)) { return; }
        const {token} = this.presentation;
        const tab = this.tab.activeTab;
        const operation = {kind: "recovery"};
        this.presentation.operation = operation;
        document.getElementById("idle-check-status").disabled = true;
        const revision = this.revision;
        const current = await currentActiveTab();
        if (!this.ownsIdle(token, tab, operation)) { return; }
        const sameCurrentTab = sameUpdateRecoveryTab(current.activeTab, recoveryTab);
        const currentRecoveryTab = sameCurrentTab ? await updateRecoveryTabFor(current.activeTab) : null;
        if (!this.ownsIdle(token, tab, operation)) { return; }
        if (revision !== this.revision || !this.isEmpty || this.refresh.kind !== "idle") {
            this.showLoading();
            await this.refreshQueue();
            return;
        }
        if (!sameCurrentTab || !sameUpdateRecoveryTab(currentRecoveryTab, recoveryTab)) {
            Object.assign(this.tab, current, {recoveryTab: null});
            this.showLoading();
            await this.refreshQueue();
            return;
        }
        let pendingReload;
        let reloadStarted = false;
        try {
            pendingReload = browser.tabs.reload(current.activeTab.id);
            reloadStarted = true;
        } catch {}
        const outcome = reloadStarted ? await settleExtensionMessage(pendingReload) : {status: "failure"};
        if (!this.ownsIdle(token, tab, operation)) { return; }
        if (outcome.status === "response") {
            this.presentation = {kind: "closed"};
            window.close();
            return;
        }
        this.presentation.operation = null;
        this.renderIdleControls();
        show("idle-check-status");
        setText("idle-connection", localized("failedToLoad", "Failed to load"));
    }
}

class PopupRequestController {
    constructor(owner, request) {
        this.owner = owner;
        this.request = request;
        this.presentation = {
            accounts: null, chainId: null, networksKey: null, cluster: null,
            lastStateJSON: null, alertKey: null, alertReturnFocus: null,
            lastEditorRequestKey: null,
        };
        this.nativeState = null;
        this.activity = {kind: "viewing"};
        this.read = {kind: "idle"};
        this.refreshDelay = TRANSACTION_REFRESH_INTERVAL;
    }

    get isActive() {
        return this.owner.presentation.kind === "review" &&
            this.owner.currentRequest === this &&
            !["reconciling", "disposed"].includes(this.activity.kind);
    }

    get state() { return this.nativeState; }
    get isSubmitting() { return this.activity.kind === "submitting"; }
    get presentationActivity() {
        return this.isSubmitting ? this.activity.source : this.activity;
    }
    get editorDraft() {
        return this.presentationActivity.kind === "editing" ? this.presentationActivity.draft : null;
    }

    allows(action) {
        return this.isActive && this.presentationActivity.kind !== "failed" &&
            hasApprovalAction(this.state, action);
    }

    stopRead() {
        if (this.read.kind === "scheduled") { clearTimeout(this.read.timerId); }
        this.read = {kind: "idle"};
    }

    scheduleRead() {
        if (this.read.kind === "scheduled") { this.stopRead(); }
        if (!this.isActive || this.activity.kind !== "viewing" || this.read.kind !== "idle") { return; }
        const polling = shouldPollApprovalState(this.state);
        if (!polling && !(this.state?.state === "review" && this.state.review.kind === "sendTransaction")) { return; }
        const scheduled = {kind: "scheduled", timerId: null};
        scheduled.timerId = setTimeout(() => {
            if (this.read !== scheduled) { return; }
            this.read = {kind: "idle"};
            void this.readState({refresh: !polling});
        }, polling ? APPROVAL_POLL_INTERVAL : this.refreshDelay);
        this.read = scheduled;
    }

    async sendCommand({subject, payload, reviewToken}) {
        if (!this.isActive) { return {status: "cancelled"}; }
        try {
            const response = await settleNativeMessage(Promise.resolve(nativeMessage(
                subject, this.request.id, payload, this.request.requestToken,
                reviewToken, this.request
            )), subject === "approveRequest");
            return {status: "response", response};
        } catch {
            return {status: "failure"};
        }
    }

    async readState({refresh = false} = {}) {
        if (!this.isActive || this.activity.kind !== "viewing") { return null; }
        if (this.read.kind === "reading") { return this.read.promise; }
        this.stopRead();
        const flight = {kind: "reading", promise: null};
        this.read = flight;
        flight.promise = (async () => {
            const outcome = await this.sendCommand({subject: "getApprovalState"});
            if (!this.isActive || this.read !== flight) { return null; }
            this.read = {kind: "idle"};
            const state = this.acceptReply(outcome)?.approval;
            if (state) { this.adoptState(state, {refresh}); }
            this.scheduleRead();
            return state;
        })();
        return flight.promise;
    }

    acceptReply(outcome) {
        const reply = outcome.status === "response"
            ? BigWalletPopupWire.decodeCommandResult(outcome.response, this.request.id) : null;
        if (!reply?.approval) { this.fail(); return null; }
        if (reply.approval.state === "missing") { void this.reconcile(); return null; }
        return reply;
    }

    reconcile() {
        if (this.activity.kind === "reconciling") { return this.activity.promise; }
        if (!this.isActive) { return Promise.resolve(); }
        this.stopRead();
        this.discardSliderGesture();
        this.closeAlert(false);
        const activity = {kind: "reconciling", promise: null};
        this.activity = activity;
        activity.promise = this.owner.reconcile(this);
        return activity.promise;
    }

    fail() {
        if (!this.isActive) { return; }
        this.stopRead();
        this.discardSliderGesture();
        this.activity = {kind: "failed"};
        this.renderTransportFailure();
    }

    adoptState(state, {refresh = false} = {}) {
        if (!this.isActive || !state) { return; }
        if (this.editorDraft &&
            (state.review?.alert || !hasApprovalAction(state, "editTransaction"))) {
            this.resetEditorDraft();
        }
        this.nativeState = state;
        const unchanged = canonicalJSONString(state) === this.presentation.lastStateJSON;
        if (!refresh || !unchanged) { this.renderState(state); }
        this.refreshDelay = refresh && unchanged && STABLE_TRANSACTION_PHASES.has(state.review?.phase)
            ? Math.min(this.refreshDelay * 2, TRANSACTION_REFRESH_MAX_INTERVAL)
            : TRANSACTION_REFRESH_INTERVAL;
        this.scheduleRead();
    }

    beginAction(kind) {
        this.stopRead();
        const operation = {kind};
        this.activity = {kind: "submitting", operation, source: this.activity};
        hide("working-overlay");
        this.updateInteractionControls();
        return operation;
    }

    ownsAction(operation) {
        return this.isActive && this.isSubmitting && this.activity.operation === operation;
    }

    finishAction(operation, state, next = {kind: "viewing"}) {
        if (!this.ownsAction(operation)) { return; }
        this.activity = next;
        if (state) { this.adoptState(state); }
        this.openRequestedEditor();
        this.updateInteractionControls();
        this.scheduleRead();
    }

    completeAction(operation, outcome) {
        if (!this.ownsAction(operation)) { return; }
        const state = this.acceptReply(outcome)?.approval;
        if (state) { this.finishAction(operation, state); }
    }

    async retry() {
        if (!this.isActive || this.isSubmitting ||
            this.activity.kind !== "failed" && !this.allows("retry")) { return; }
        const operation = this.beginAction("retry");
        const outcome = await this.sendCommand({subject: "retryApproval"});
        this.completeAction(operation, outcome);
    }

    approve(payload) { return this.decide("approveRequest", payload); }
    reject() { return this.decide("rejectRequest"); }

    async decide(subject, payload) {
        if (!this.isActive || !canSubmitDecision(subject, this.state)) { return; }
        if (subject === "approveRequest") {
            if (this.activity.kind !== "viewing") { return; }
        } else {
            if (this.isSubmitting && ["approveRequest", "rejectRequest"].includes(this.activity.operation.kind)) { return; }
            this.discardSliderGesture();
            this.activity = {kind: "viewing"};
            this.closeAlert(false);
            this.syncEditor();
        }
        const reviewToken = subject === "approveRequest" ? this.state.review.reviewToken : undefined;
        const operation = this.beginAction(subject);
        const decisionPayload = subject === "approveRequest" ? {...(isRecord(payload) ? payload : {})} : undefined;
        if (decisionPayload) { delete decisionPayload.revisions; delete decisionPayload.password; }
        const outcome = await this.sendCommand({subject, payload: decisionPayload, reviewToken});
        this.completeAction(operation, outcome);
    }

    async resolveAlert(payload, reviewToken) {
        if (this.isSubmitting || !this.allows("resolveApprovalAlert") || this.state.review.reviewToken !== reviewToken) { return; }
        const operation = this.beginAction("alert");
        const outcome = await this.sendCommand({subject: "resolveApprovalAlert", payload, reviewToken});
        if (this.ownsAction(operation) && this.state?.review?.reviewToken !== reviewToken) {
            this.finishAction(operation);
            return;
        }
        this.completeAction(operation, outcome);
    }

    async setSpeed(payload, reviewToken) {
        if (!this.allows("setTransactionSpeed") ||
            !["viewing", "dragging"].includes(this.activity.kind) || !isRequestToken(reviewToken)) { return null; }
        const operation = this.beginAction("speed");
        const staleReview = this.state?.review?.reviewToken !== reviewToken;
        const outcome = await this.sendCommand(staleReview
            ? {subject: "getApprovalState"}
            : {subject: "setTransactionSpeed", payload, reviewToken});
        if (!this.ownsAction(operation)) { return false; }
        const reply = this.acceptReply(outcome);
        if (reply) { this.finishAction(operation, reply.approval); }
        return !staleReview && reply?.status === "ok" && this.isActive;
    }

    updateInteractionControls() {
        if (!this.isActive) { return; }
        const editing = this.editorDraft !== null;
        const busy = this.isSubmitting;
        document.getElementById("tx-slider").disabled = busy || editing || !this.allows("setTransactionSpeed");
        document.getElementById("editor-apply").disabled = busy || !this.allows("editTransaction");
        document.getElementById("editor-suggested").disabled = busy || !this.allows("editTransaction");
        for (const field of Object.values(TRANSACTION_EDITOR_FIELDS)) {
            document.getElementById(field).disabled = busy;
        }
        document.getElementById("network-select").disabled = busy;
        for (const id of ["accounts-list", "clusters"]) {
            for (const row of document.getElementById(id).children) { row.disabled = busy; }
        }
        document.getElementById("button-reject").disabled = !this.allows("reject") ||
            busy && this.activity.operation.kind === "approveRequest";
        this.syncEditor();
        this.updateApproveEnabled(this.state);
    }

    requestFor(value) {
        if (!this.isActive) { return null; }
        return typeof value === "undefined" || value === this.request.id ||
            sameRequest(value, this.request) ? this.request : null;
    }

    start() {
        if (!this.isActive) { return; }
        this.resetEditorDraft();
        show("working-overlay");
        setText("request-title", "");
        setText("request-host", this.request.host);
        hide("request-error");
        for (const section of ["accounts", "message", "transaction", "chain"]) {
            hide("section-" + section);
        }
        this.syncEditor();
        return this.readState();
    }

    dispose() {
        if (this.activity.kind !== "disposed") {
            this.stopRead();
            this.discardSliderGesture();
            this.activity = {kind: "disposed"};
        }
        this.closeAlert(false);
    }

    closeAlert(restoreFocus) {
        if (this.owner.currentRequest !== this) { return; }
        const overlay = document.getElementById("alert-overlay");
        const wasOpen = this.presentation.alertKey !== null || !overlay.classList.contains("hidden");
        const focusTarget = this.presentation.alertReturnFocus;
        hide("alert-overlay");
        document.getElementById("screen-request").inert = false;
        document.getElementById("alert-buttons").innerHTML = "";
        this.presentation.alertKey = null;
        this.presentation.alertReturnFocus = null;
        if (restoreFocus && wasOpen && focusTarget &&
            focusTarget.isConnected !== false && focusTarget.disabled !== true &&
            typeof focusTarget.focus === "function") {
            focusTarget.focus();
        }
    }

    renderState(state) {
        if (!this.isActive) { return; }
        this.presentation.lastStateJSON = canonicalJSONString(state);
        show("screen-request");
        hide("screen-idle");
        document.getElementById("button-approve").textContent =
            hasApprovalAction(state, "retry") || shouldRefreshAccountSelection(state)
                ? localized("refresh", "Refresh")
                : state.review?.primaryTitle || localized("ok", "OK");
        document.getElementById("button-reject").disabled = !canRejectApprovalState(state);
        this.updateApproveEnabled(state);
        const isBusy = shouldPollApprovalState(state);
        setHidden("working-overlay", !isBusy);
        if (!state.review) {
            this.closeAlert(false);
            this.discardSliderGesture();
            document.getElementById("tx-slider").disabled = true;
            document.getElementById("editor-apply").disabled = true;
            document.getElementById("editor-suggested").disabled = true;
            if (isBusy) {
                document.getElementById("screen-request").inert = true;
                return;
            }
            this.resetEditorDraft();
            hide("tx-editor");
        } else if (state.review.kind === "sendTransaction" && state.review.phase === "finished") {
            this.resetEditorDraft();
        }

        setText("request-title", state.review?.title || "");
        setText("request-host", state.host || "");
        setOptionalText("request-error", "request-error", state.error);
        hide("section-accounts");
        hide("section-message");
        hide("section-transaction");
        hide("section-chain");

        switch (state.review?.kind) {
            case "selectAccount":
            case "switchAccount":
                this.renderAccountSelection(state);
                break;
            case "signMessage":
                this.renderSignMessage(state);
                break;
            case "sendTransaction":
                this.renderTransaction(state);
                break;
            case "addChain":
                renderAddChain(state);
                break;
        }
        this.renderAlertIfNeeded(state);
        this.updateInteractionControls();
    }

    renderAccountSelection(state) {
        const review = state.review;
        show("section-accounts");
        this.reconcileAccountSelection(state);

        if (review.canSelectNetwork && review.networks) {
            show("network-row");
            const select = document.getElementById("network-select");
            const networksKey = JSON.stringify(review.networks.map(network => [
                network.chainId,
                network.name,
                network.isCustom === true,
            ]));
            if (networksKey !== this.presentation.networksKey) {
                this.presentation.networksKey = networksKey;
                select.innerHTML = "";
                for (const network of review.networks) {
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
            if (this.presentation.chainId !== null) {
                select.value = this.presentation.chainId;
            }
        } else {
            hide("network-row");
        }

        setOptionalText("accounts-empty", "accounts-empty", review.emptyMessage);

        this.renderCheckedList("accounts-list", review.accounts || [], "account-row",
                          (row, account) => { fillAccountRow(row, account, true); },
                          account => this.isSelectedAccount(account),
                          account => this.toggleAccount(account));
    }

    reconcileAccountSelection(state) {
        const review = state.review;
        const availableAccounts = review.accounts || [];
        if (this.presentation.accounts === null) {
            this.presentation.accounts = availableAccounts
                .filter(account => account.isSelected)
                .map(accountIdentity);
        } else {
            this.presentation.accounts = this.presentation.accounts
                .map(selected => availableAccounts.find(account => sameAccount(selected, account)))
                .filter(account => typeof account !== "undefined")
                .map(accountIdentity);
        }

        if (!review.canSelectNetwork || !Array.isArray(review.networks)) {
            this.presentation.chainId = null;
            return;
        }
        const selectedNetwork = review.networks.find(
            network => network.chainId === this.presentation.chainId
        ) || review.networks.find(network => network.isSelected) || review.networks[0];
        this.presentation.chainId = selectedNetwork ? selectedNetwork.chainId : null;
    }

    renderCheckedList(containerId, items, rowClass, fillRow, isSelected, select) {
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
                if (!this.isActive || this.activity.kind !== "viewing") { return; }
                select(item);
                this.renderState(this.state);
                const replacement = document.getElementById(containerId).children[index];
                if (replacement && typeof replacement.focus === "function") {
                    replacement.focus();
                }
            });
            container.appendChild(row);
        }
    }

    isSelectedAccount(account) {
        return this.presentation.accounts.some(selected => sameAccount(selected, account));
    }

    toggleAccount(account) {
        if (this.isSelectedAccount(account)) {
            this.presentation.accounts = this.presentation.accounts.filter(selected => !sameAccount(selected, account));
        } else {
            this.presentation.accounts = this.presentation.accounts.filter(selected => selected.coin !== account.coin);
            this.presentation.accounts.push(accountIdentity(account));
        }
    }

    canApproveAccountSelection(state) {
        const review = state.review;
        if (!Array.isArray(this.presentation.accounts)) {
            return false;
        }
        if (this.presentation.accounts.length === 0) {
            return review.allowsEmptySelection === true;
        }
        const selectedEthereum = this.presentation.accounts.some(account => account.coin === "ethereum");
        return !selectedEthereum || isCanonicalEthereumChainId(this.presentation.chainId);
    }

    updateApproveEnabled(state) {
        const approve = document.getElementById("button-approve");
        if (this.presentationActivity.kind === "failed") {
            approve.disabled = this.isSubmitting;
        } else if (this.activity.kind !== "viewing") {
            approve.disabled = true;
        } else if (hasApprovalAction(state, "retry") || shouldRefreshAccountSelection(state)) {
            approve.disabled = false;
        } else if (!hasApprovalAction(state, "approve")) {
            approve.disabled = true;
        } else if (state.review.kind === "selectAccount" || state.review.kind === "switchAccount") {
            approve.disabled = !this.canApproveAccountSelection(state);
        } else if (state.review.kind === "signMessage") {
            approve.disabled = state.review.requiresClusterSelection === true && this.presentation.cluster === null;
        } else {
            approve.disabled = false;
        }
    }

    renderSignMessage(state) {
        const review = state.review;
        show("section-message");
        renderAccountRow("signing-account", review.account);
        setText("message-meta", review.meta || "");
        const clusters = review.clusters || [];
        setHidden("clusters", !(clusters.length > 0));
        if (clusters.length > 0) {
            const current = clusters.find(cluster => cluster.value === this.presentation.cluster);
            if (!current) {
                const selected = clusters.find(c => c.isSelected);
                this.presentation.cluster = selected ? selected.value : null;
            }
            this.renderCheckedList("clusters", clusters, "cluster-row",
                              (row, cluster) => {
                                  const label = document.createElement("span");
                                  label.textContent = cluster.label;
                                  row.appendChild(label);
                              },
                              cluster => cluster.value === this.presentation.cluster,
                              cluster => { this.presentation.cluster = cluster.value; });
        } else {
            this.presentation.cluster = null;
        }
    }

    renderTransaction(state) {
        const review = state.review;
        show("section-transaction");
        renderAccountRow("tx-account", review.account);
        setText("tx-network", review.networkName || "");
        setOptionalText("tx-balance", "tx-balance-row", review.balance);
        setOptionalText("tx-value", "tx-value-row", review.valueLine);
        const feeLines = document.getElementById("tx-fee-lines");
        feeLines.innerHTML = "";
        for (const line of review.feeLines || []) {
            const div = document.createElement("div");
            div.className = "fee-line";
            div.textContent = line;
            feeLines.appendChild(div);
        }
        if (review.phase === "preparing" || review.phase === "idle") {
            const div = document.createElement("div");
            div.className = "fee-line";
            div.textContent = localized("calculating", "Calculating...");
            feeLines.appendChild(div);
        }

        const sliderState = review.slider && review.slider.visible ? review.slider : null;
        setHidden("tx-slider-row", !sliderState);
        if (sliderState) {
            const slider = document.getElementById("tx-slider");
            const firstFeeLine = feeLines.children[0]?.textContent ||
                localized("calculating", "Calculating...");
            slider.max = sliderState.maximum || 200;
            slider.value = this.presentationActivity.kind === "dragging"
                ? this.presentationActivity.gesture.value : sliderState.position ?? 100;
            slider.disabled = !hasApprovalAction(state, "setTransactionSpeed");
            slider.setAttribute("aria-valuetext", firstFeeLine);
        }

        setOptionalText("tx-data", "tx-data-details", review.dataInterpretation);

        const canApplyEdits = hasApprovalAction(state, "editTransaction");
        document.getElementById("editor-apply").disabled = !canApplyEdits;
        document.getElementById("editor-suggested").disabled = !canApplyEdits;
        if (canApplyEdits || this.editorDraft) {
            show("tx-editor");
            this.populateEditor(state);
            this.openRequestedEditor();
        } else {
            hide("tx-editor");
        }
    }

    openRequestedEditor() {
        const token = this.state?.review?.editorRequestToken;
        if (this.isSubmitting || !this.allows("editTransaction") || typeof token !== "number") { return; }
        const key = this.request.requestToken + ":" + token;
        if (this.presentation.lastEditorRequestKey === key) { return; }
        this.presentation.lastEditorRequestKey = key;
        if (!this.state.review.alert) { this.openEditor(); }
    }

    populateEditor(state) {
        const editor = state.review.editor;
        setHidden("editor-eip1559", !editor.usesEIP1559);
        setHidden("editor-legacy", editor.usesEIP1559);
        const values = this.editorDraft?.values || transactionEditorValues(editor);
        for (const [name, value] of Object.entries(values)) {
            const field = document.getElementById(TRANSACTION_EDITOR_FIELDS[name]);
            if (field.value !== value) { field.value = value; }
        }
        const hasSuggested = editor.suggestedGasPriceGwei != null || editor.suggestedMaxFeePerGasGwei != null;
        setHidden("editor-suggested", !hasSuggested);
        this.syncEditor();
    }

    syncEditor() {
        const draft = this.editorDraft;
        document.getElementById("tx-editor").open = draft !== null;
        const error = draft?.error;
        if (error === "invalidValues") {
            setText("edits-error", localized("invalidValues", "Invalid values"));
        } else if (error === "reviewChanged") {
            setText("edits-error", localized("reviewChanged", "Review changed. Check the values and apply again."));
        }
        setHidden("edits-error", !error);
    }

    resetEditorDraft() {
        if (this.activity.kind === "editing") { this.activity = {kind: "viewing"}; }
        this.syncEditor();
    }

    async approveCurrent() {
        if (!this.isActive || !["viewing", "failed"].includes(this.activity.kind)) { return; }
        if (this.activity.kind === "failed") {
            await this.retry();
            return;
        }
        if (!this.state) { return; }
        if (hasApprovalAction(this.state, "retry")) {
            await this.retry();
            return;
        }
        if (shouldRefreshAccountSelection(this.state)) {
            document.getElementById("button-approve").disabled = true;
            await this.readState();
            return;
        }
        const payload = {};
        if (this.state.review?.kind === "selectAccount" || this.state.review?.kind === "switchAccount") {
            if (!this.canApproveAccountSelection(this.state)) { return; }
            payload.selectedAccounts = this.presentation.accounts;
            if (this.state.review?.canSelectNetwork &&
                isCanonicalEthereumChainId(this.presentation.chainId)) {
                payload.chainId = this.presentation.chainId;
            }
        } else if (this.state.review?.kind === "signMessage" && this.presentation.cluster) {
            payload.cluster = this.presentation.cluster;
        }
        await this.approve(payload);
    }

    async rejectCurrent() {
        await this.reject();
    }

    openEditor() {
        if (this.activity.kind !== "viewing" || !this.allows("editTransaction") || this.state.review?.alert) {
            this.syncEditor();
            return;
        }
        this.stopRead();
        const editor = this.state.review.editor;
        this.activity = {kind: "editing", draft: {
            reviewToken: this.state.review.reviewToken,
            usesEIP1559: editor.usesEIP1559,
            values: transactionEditorValues(editor),
            error: null,
        }};
        this.populateEditor(this.state);
        this.updateInteractionControls();
    }

    editorToggled() {
        if (!this.isActive) { return; }
        const wantsOpen = document.getElementById("tx-editor").open;
        if (this.isSubmitting) {
            this.syncEditor();
        } else if (wantsOpen) {
            this.openEditor();
        } else {
            this.resetEditorDraft();
            this.updateInteractionControls();
            this.scheduleRead();
        }
    }

    editField(name, value) {
        if (!this.isActive || this.activity.kind !== "editing" ||
            !Object.hasOwn(this.activity.draft.values, name)) { return; }
        this.activity.draft.values[name] = value;
    }

    beginSliderInteraction(request, reviewToken = this.state?.review?.reviewToken) {
        const capturedRequest = this.requestFor(request);
        if (!this.allows("setTransactionSpeed") || this.activity.kind !== "viewing" ||
            !capturedRequest || !isRequestToken(reviewToken)) { return false; }
        this.stopRead();
        ignoreSliderUntilRelease = false;
        this.activity = {kind: "dragging", gesture: {
            reviewToken, value: Number(document.getElementById("tx-slider").value),
        }};
        this.updateInteractionControls();
        return true;
    }

    updateSliderValue() {
        if (this.activity.kind === "dragging") {
            this.activity.gesture.value = Number(document.getElementById("tx-slider").value);
        }
    }

    finishSliderInteraction(interaction, request) {
        if (this.activity.kind !== "dragging" || !this.requestFor(request)) { return null; }
        this.updateSliderValue();
        const gesture = this.activity.gesture;
        return this.setSpeed({interaction, value: gesture.value}, gesture.reviewToken);
    }

    async applyEdits() { await this.applyEditor(false); }
    async applySuggested() { await this.applyEditor(true); }

    async applyEditor(suggested) {
        if (!this.allows("editTransaction") || this.activity.kind !== "editing") { return; }
        const draft = this.activity.draft;
        const payload = suggested ? {mode: "suggested"} : {mode: "custom", ...draft.values};
        const operation = this.beginAction("edits");
        const outcome = await this.sendCommand({subject: "applyTransactionEdits", payload, reviewToken: draft.reviewToken});
        if (!this.ownsAction(operation)) { return; }
        const reply = this.acceptReply(outcome);
        if (!reply) { return; }
        const state = reply.approval;
        const preservesDraft = state.review?.kind === "sendTransaction" &&
            !state.review.alert && hasApprovalAction(state, "editTransaction") &&
            state.review.editor.usesEIP1559 === draft.usesEIP1559;
        let next = {kind: "viewing"};
        if (preservesDraft && (reply.status === "ignored" || state.editsError)) {
            draft.reviewToken = state.review.reviewToken;
            draft.error = reply.status === "ignored" ? "reviewChanged" : "invalidValues";
            next = {kind: "editing", draft};
        }
        this.finishAction(operation, state, next);
    }

    renderAlertIfNeeded(state) {
        if (!hasApprovalAction(state, "resolveApprovalAlert") || !state.review?.alert) {
            this.closeAlert(state.state === "review");
            return;
        }
        const alert = state.review.alert;
        const title = alert.title || "";
        const message = alert.message || "";
        const actions = alert.actions;
        const alertKey = JSON.stringify([
            title,
            message,
            actions.map(action => [action.title, action.action]),
        ]);
        const overlay = document.getElementById("alert-overlay");
        if (this.presentation.alertKey === alertKey && !overlay.classList.contains("hidden")) {
            return;
        }
        if (this.presentation.alertKey === null) {
            const activeElement = document.activeElement;
            this.presentation.alertReturnFocus = activeElement && typeof activeElement.focus === "function"
                ? activeElement
                : null;
        }
        this.presentation.alertKey = alertKey;
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
                if (!this.isActive) { return; }
                const reviewToken = this.state?.review?.reviewToken;
                const currentAlert = this.state?.review?.alert;
                if (!hasApprovalAction(this.state, "resolveApprovalAlert") ||
                    !isRequestToken(reviewToken) || !currentAlert ||
                    !currentAlert.actions.some(currentAction =>
                        currentAction.action === action.action &&
                        currentAction.title === action.title
                    )) {
                    return;
                }
                if (this.isSubmitting && action.action === "cancel" && this.allows("reject")) {
                    await this.reject();
                } else {
                    await this.resolveAlert({action: action.action}, reviewToken);
                }
            });
            buttons.appendChild(button);
        }
        document.getElementById("screen-request").inert = true;
        show("alert-overlay");
        const focusTarget = buttons.children[0] || document.getElementById("alert-box");
        focusTarget.focus();
    }

    renderTransportFailure() {
        this.presentation.lastStateJSON = null;
        this.closeAlert(false);
        this.syncEditor();
        this.renderState({
            id: this.request.id,
            state: "error",
            actions: ["retry"],
            host: this.state?.host,
            error: localized("failedToLoad", "Failed to load"),
        });
    }

    discardSliderGesture() {
        if (this.activity.kind === "dragging") {
            ignoreSliderUntilRelease = true;
            this.activity = {kind: "viewing"};
        }
    }
}

function extensionPrivateBrowsing() {
    return browser.extension?.inIncognitoContext === true;
}

function currentPrivateBrowsing() {
    return popupQueue?.privateBrowsing ?? extensionPrivateBrowsing();
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

function localized(key, fallback) {
    return popupStrings[key] || fallback;
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
    popupStrings = dictionary;
    for (const element of document.querySelectorAll("[data-string]")) {
        const text = popupStrings[element.dataset.string];
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
        return {activeTab: tabIdentity(tab), privateBrowsing: tab.incognito};
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
    return {
        activeTab: tabIdentity(tab, windowIncognito),
        privateBrowsing: privateBrowsingForTab(tab, windowIncognito),
    };
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
    const response = outcome.status === "response"
        ? BigWalletBridgeWire.decodePageResponse(outcome.response) : null;
    return response?.kind === "configuration" ? response.state : null;
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
        const outcome = await settleExtensionMessage(Promise.resolve().then(() => nativeMessage("getPendingRequests", genId())));
        if (outcome.status !== "response") { return null; }
        const response = BigWalletPopupWire.decodeQueue(outcome.response);
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

function sameRequest(left, right) {
    return !!left && !!right &&
        left.id === right.id &&
        left.requestToken === right.requestToken;
}

function hasApprovalAction(state, action) {
    return state?.actions?.includes(action) === true;
}

function shouldPollApprovalState(state) {
    return state?.state === "authenticating" || state?.state === "working";
}

function canRejectApprovalState(state) {
    return hasApprovalAction(state, "reject");
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
    return BigWalletPopupWire.accountIdentityKey(left) === BigWalletPopupWire.accountIdentityKey(right);
}

function shouldRefreshAccountSelection(state) {
    return (state.review?.kind === "selectAccount" || state.review?.kind === "switchAccount") &&
        Array.isArray(state.review?.accounts) && state.review?.accounts.length === 0 &&
        state.review?.allowsEmptySelection === false;
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

function renderAddChain(state) {
    show("section-chain");
    setText("chain-name", state.review?.chainName || "");
    setText("chain-rpc", state.review?.rpcURL || "");
}

function canSubmitDecision(subject, state) {
    return subject === "rejectRequest"
        ? canRejectApprovalState(state)
        : hasApprovalAction(state, "approve") && isRequestToken(state.review?.reviewToken);
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

document.addEventListener("DOMContentLoaded", () => {
    popupQueue = new PopupQueueController();
    browser.runtime.onMessage.addListener((request, sender) => {
        const senderContext = BigWalletBridgeWire.authorizeRuntimeMessage(
            "popup", request, sender, browser.runtime
        );
        if (!senderContext) { return false; }
        if (isPendingRequestAvailable(request)) { popupQueue.invalidate(); }
        return false;
    });
    document.getElementById("button-approve").addEventListener("click", () => popupQueue.currentRequest?.approveCurrent());
    document.getElementById("button-reject").addEventListener("click", () => popupQueue.currentRequest?.rejectCurrent());
    document.getElementById("idle-switch-account").addEventListener("click", () => popupQueue.switchAccountFromIdle());
    document.getElementById("idle-check-status").addEventListener("click", () => popupQueue.refreshIdleStatus());
    document.getElementById("editor-apply").addEventListener("click", () => popupQueue.currentRequest?.applyEdits());
    document.getElementById("editor-suggested").addEventListener("click", () => popupQueue.currentRequest?.applySuggested());
    document.getElementById("network-select").addEventListener("change", () => {
        if (popupQueue.currentRequest?.isActive && popupQueue.currentRequest.activity.kind === "viewing") {
            popupQueue.currentRequest.presentation.chainId = document.getElementById("network-select").value;
        }
    });
    document.getElementById("tx-editor-summary").addEventListener("click", event => {
        event.preventDefault();
        const controller = popupQueue.currentRequest;
        if (!controller?.isActive) { return; }
        const editor = document.getElementById("tx-editor");
        editor.open = !editor.open;
        controller.editorToggled();
    });
    document.getElementById("tx-editor").addEventListener("toggle", () => popupQueue.currentRequest?.editorToggled());

    for (const [name, id] of Object.entries(TRANSACTION_EDITOR_FIELDS)) {
        document.getElementById(id).addEventListener("input", event => {
            popupQueue.currentRequest?.editField(name, event.target.value);
        });
    }

    const slider = document.getElementById("tx-slider");
    slider.addEventListener("pointerdown", () => {
        popupQueue.currentRequest?.beginSliderInteraction();
    });
    slider.addEventListener("input", () => {
        if (ignoreSliderUntilRelease) { return; }
        if (popupQueue.currentRequest?.activity.kind !== "dragging") {
            popupQueue.currentRequest?.beginSliderInteraction();
        }
        popupQueue.currentRequest?.updateSliderValue();
    });
    const endDrag = interaction => {
        if (ignoreSliderUntilRelease) {
            ignoreSliderUntilRelease = false;
            return;
        }
        popupQueue.currentRequest?.finishSliderInteraction(interaction);
    };
    slider.addEventListener("pointerup", () => { endDrag("ended"); });
    slider.addEventListener("pointercancel", () => {
        endDrag("cancelled");
    });
    slider.addEventListener("change", () => { endDrag("ended"); });

    void popupQueue.boot();
});
