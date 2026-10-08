
// ∅ 2026 lil org

const TRANSACTION_REFRESH_INTERVAL = 600;
const TRANSACTION_REFRESH_MAX_INTERVAL = 10000;
const APPROVAL_POLL_INTERVAL = 400;
const NATIVE_MESSAGE_TIMEOUT = 5000;
const RESPONSE_DELIVERY_TIMEOUT = NATIVE_MESSAGE_TIMEOUT * 3;
const MANUAL_SWITCH_TIMEOUT = 60 * 1000;
const NATIVE_OPERATION_RELAY_TIMEOUT = 190 * 1000;
const MAX_RESPONSE_READY_IDS = BigWalletBridgeWire.MAX_RESPONSE_READY_IDS;
const WORKFLOW_VERSION = BigWalletBridgeWire.WORKFLOW_VERSION;
const BUILD_VERSION = BigWalletBridgeWire.BUILD_VERSION;
const UPDATE_RECOVERY_STORAGE_KEY = "workflowUpdateRecoveryNeeded";
const TRANSACTION_EDITOR_FIELDS = {
    nonce: "edit-nonce",
    gasPriceGwei: "edit-gas-price",
    maxPriorityFeePerGasGwei: "edit-max-priority",
    maxFeePerGasGwei: "edit-max-fee",
};
var configurationIdentityForURL = BigWalletBridgeWire.configurationIdentityForURL;
var genId = BigWalletBridgeWire.genId;
var genPrivateToken = BigWalletBridgeWire.genPrivateToken;
var decodeWireMessage = BigWalletBridgeWire.decodeMessage;
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

    isReviewing(controller) {
        return this.presentation.kind === "review" && this.presentation.controller === controller;
    }

    replacePresentation(next) {
        const previous = this.currentRequest;
        if (previous && (next.kind !== "review" || next.controller !== previous)) {
            previous.release();
        }
        this.presentation = next;
    }

    close() {
        if (this.refresh.kind === "scheduled") { clearTimeout(this.refresh.timer); }
        this.refresh = {kind: "idle"};
        this.replacePresentation({kind: "closed"});
        window.close();
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
            this.replacePresentation({kind: "loading"});
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
        hide("screen-loading");
        const requests = this.snapshot.kind === "ready" ? this.snapshot.requests : null;
        if (requests) { setPendingRequestBadge(requests.length); }
        if (!requests || requests.length === 0) {
            this.replacePresentation({kind: "idle", token: {}, operation: null});
            void this.renderIdle();
            return;
        }
        const controller = new PopupRequestController(this, requests[0]);
        this.replacePresentation({kind: "review", controller});
        setHidden("queue-indicator", requests.length <= 1);
        if (requests.length > 1) {
            setText("queue-indicator", formatted(localized("queuePosition", "%1$@ of %2$@"), "1", String(requests.length)));
        }
        hide("screen-idle");
        void controller.start();
    }

    reconcile(controller) {
        if (this.presentation.kind === "reconciling" && this.currentRequest === controller) {
            return this.presentation.promise;
        }
        if (!this.isReviewing(controller)) { return Promise.resolve(); }
        const transition = {kind: "reconciling", controller, promise: null};
        this.replacePresentation(transition);
        transition.promise = (async () => {
            const snapshot = await this.refreshQueue();
            if (snapshot !== null && this.snapshot === snapshot && this.isEmpty &&
                !this.showsUpdateRecovery && this.refresh.kind === "idle" &&
                this.presentation.kind === "idle" && this.presentation.operation === null) {
                this.close();
            }
        })();
        return transition.promise;
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
        this.replacePresentation({kind: "loading"});
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
            this.close();
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
            lastStateJSON: null,
        };
        this.nativeState = null;
        this.interaction = {kind: "viewing"};
        this.command = null;
        this.read = {kind: "idle"};
        this.refreshDelay = TRANSACTION_REFRESH_INTERVAL;
    }

    get isActive() { return this.owner.isReviewing(this); }
    get state() { return this.nativeState; }
    get isSubmitting() { return this.command !== null; }
    get editorDraft() {
        return this.interaction.kind === "editing" ? this.interaction.draft : null;
    }

    allows(action) {
        return this.isActive && this.interaction.kind !== "failed" &&
            hasApprovalAction(this.state, action);
    }

    stopRead() {
        if (this.read.kind === "scheduled") { clearTimeout(this.read.timerId); }
        this.read = {kind: "idle"};
    }

    scheduleNextRead() {
        if (!this.isActive || this.isSubmitting || this.interaction.kind !== "viewing" || this.read.kind !== "idle") { return; }
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
        if (!this.isActive) { return null; }
        try {
            const response = await settleNativeMessage(Promise.resolve(nativeMessage(
                subject, this.request.id, payload, this.request.requestToken,
                reviewToken
            )), subject === "approveRequest");
            return BigWalletPopupWire.decodeCommandResult(response, this.request.id);
        } catch {
            return null;
        }
    }

    async readState({refresh = false} = {}) {
        if (!this.isActive || this.isSubmitting || this.interaction.kind !== "viewing") { return null; }
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
            return state;
        })();
        return flight.promise;
    }

    acceptReply(reply) {
        if (!reply?.approval) { this.failTransport(); return null; }
        if (reply.approval.state === "missing") { void this.reconcile(); return null; }
        return reply;
    }

    reconcile() { return this.owner.reconcile(this); }

    setInteraction(next) {
        if (this.interaction.kind === "dragging" && next !== this.interaction) {
            ignoreSliderUntilRelease = true;
        }
        this.interaction = next;
    }

    changeInteraction(next) {
        if (!this.isActive || this.isSubmitting) { return; }
        this.stopRead();
        this.setInteraction(next);
        if (next.kind === "editing") { this.populateEditor(this.state); }
        this.updateInteractionControls();
        this.scheduleNextRead();
    }

    adoptState(state, {refresh = false, interaction = this.interaction} = {}) {
        if (!this.isActive) { return; }
        this.stopRead();
        if (interaction.kind === "editing" && !hasApprovalAction(state, "editTransaction") ||
            interaction.kind === "dragging" && !state.review) {
            interaction = {kind: "viewing"};
        }
        this.setInteraction(interaction);
        const unchanged = canonicalJSONString(state) === this.presentation.lastStateJSON;
        const revealNotice = state.review?.kind === "sendTransaction" && state.review.notice &&
            state.review.reviewToken !== this.state?.review?.reviewToken;
        this.nativeState = state;
        this.refreshDelay = refresh && unchanged && state.review?.canBackOffRefresh === true
            ? Math.min(this.refreshDelay * 2, TRANSACTION_REFRESH_MAX_INTERVAL)
            : TRANSACTION_REFRESH_INTERVAL;
        if (interaction.kind === "failed") { this.renderTransportFailure(); }
        else if (!refresh || !unchanged) { this.renderState(state); }
        if (revealNotice) { document.getElementById("tx-notice").scrollIntoView({block: "nearest"}); }
        this.updateInteractionControls();
        this.scheduleNextRead();
    }

    failTransport() {
        if (!this.isActive) { return; }
        this.stopRead();
        this.command = null;
        this.setInteraction({kind: "failed"});
        this.renderTransportFailure();
        this.updateInteractionControls();
    }

    beginCommand(kind) {
        this.stopRead();
        if (kind === "rejectRequest") { this.setInteraction({kind: "viewing"}); }
        const command = {kind};
        this.command = command;
        hide("working-overlay");
        this.updateInteractionControls();
        return command;
    }

    ownsCommand(command) {
        return this.isActive && this.command === command;
    }

    finishCommand(command, state, next = {kind: "viewing"}) {
        if (!this.ownsCommand(command)) { return; }
        this.command = null;
        this.adoptState(state, {interaction: next});
    }

    completeCommand(command, outcome) {
        if (!this.ownsCommand(command)) { return; }
        const state = this.acceptReply(outcome)?.approval;
        if (state) { this.finishCommand(command, state); }
    }

    async retry() {
        if (!this.isActive || this.isSubmitting ||
            this.interaction.kind !== "failed" && !this.allows("retry")) { return; }
        const operation = this.beginCommand("retry");
        const outcome = await this.sendCommand({subject: "retryApproval"});
        this.completeCommand(operation, outcome);
    }

    approve(payload) { return this.decide("approveRequest", payload); }
    reject() { return this.decide("rejectRequest"); }

    async decide(subject, payload) {
        if (!this.isActive || !canSubmitDecision(subject, this.state)) { return; }
        if (subject === "approveRequest") {
            if (this.isSubmitting || this.interaction.kind !== "viewing") { return; }
        } else {
            if (this.isSubmitting && ["approveRequest", "rejectRequest"].includes(this.command.kind)) { return; }
        }
        const reviewToken = subject === "approveRequest" ? this.state.review.reviewToken : undefined;
        const operation = this.beginCommand(subject);
        const decisionPayload = subject === "approveRequest" ? {...(isRecord(payload) ? payload : {})} : undefined;
        if (decisionPayload) { delete decisionPayload.password; delete decisionPayload.revisions; delete decisionPayload.executionDeadline; }
        const outcome = await this.sendCommand({subject, payload: decisionPayload, reviewToken});
        this.completeCommand(operation, outcome);
    }

    async retryTransaction() {
        const reviewToken = this.state?.review?.reviewToken;
        if (this.isSubmitting || this.interaction.kind !== "viewing" ||
            !this.allows("retryTransaction") || !isRequestToken(reviewToken)) { return; }
        const command = this.beginCommand("retryTransaction");
        const outcome = await this.sendCommand({subject: "retryTransaction", reviewToken});
        this.completeCommand(command, outcome);
    }

    async setSpeed(payload, reviewToken) {
        if (this.isSubmitting || !this.allows("setTransactionSpeed") ||
            !["viewing", "dragging"].includes(this.interaction.kind) || !isRequestToken(reviewToken)) { return null; }
        const operation = this.beginCommand("speed");
        const staleReview = this.state?.review?.reviewToken !== reviewToken;
        const outcome = await this.sendCommand(staleReview
            ? {subject: "getApprovalState"}
            : {subject: "setTransactionSpeed", payload, reviewToken});
        if (!this.ownsCommand(operation)) { return false; }
        const reply = this.acceptReply(outcome);
        if (reply) { this.finishCommand(operation, reply.approval); }
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
            busy && this.command.kind === "approveRequest";
        this.syncEditor();
        this.updateApproveEnabled(this.state);
    }

    start() {
        if (!this.isActive) { return; }
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

    release() {
        this.stopRead();
        this.command = null;
        if (this.interaction.kind === "dragging") { ignoreSliderUntilRelease = true; }
    }

    renderState(state) {
        if (!this.isActive) { return; }
        this.presentation.lastStateJSON = canonicalJSONString(state);
        show("screen-request");
        hide("screen-idle");
        const isBusy = shouldPollApprovalState(state);
        document.getElementById("screen-request").inert = isBusy;
        setHidden("working-overlay", !isBusy);
        if (!state.review) {
            if (isBusy) { return; }
            hide("tx-editor");
        }

        setText("request-title", state.review?.title || "");
        setText("request-host", state.host || "");
        setOptionalText("request-error", "request-error", state.error);
        hide("section-accounts");
        hide("section-message");
        hide("section-transaction");
        hide("section-chain");

        switch (state.review?.kind) {
            case "accountSelection":
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
                if (!this.isActive || this.isSubmitting || this.interaction.kind !== "viewing") { return; }
                select(item);
                this.adoptState(this.state);
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

    primaryAction(state) {
        if (this.interaction.kind === "failed" || hasApprovalAction(state, "retry")) {
            return {kind: "retryApproval", title: localized("refresh", "Refresh")};
        }
        if (shouldRefreshAccountSelection(state)) {
            return {kind: "refresh", title: localized("refresh", "Refresh")};
        }
        const approve = {kind: "approve", title: state?.review?.primaryTitle || localized("ok", "OK")};
        if (hasApprovalAction(state, "approve")) { return approve; }
        if (hasApprovalAction(state, "retryTransaction")) {
            return {kind: "retryTransaction", title: localized("tryAgain", "Try again")};
        }
        if (state?.review?.kind === "sendTransaction" && hasApprovalAction(state, "editTransaction")) {
            return {kind: "edit", title: localized("editFees", "Edit fees")};
        }
        return approve;
    }

    updateApproveEnabled(state) {
        const approve = document.getElementById("button-approve");
        const action = this.primaryAction(state);
        if (approve.textContent !== action.title) { approve.textContent = action.title; }
        if (this.interaction.kind === "failed") {
            approve.disabled = this.isSubmitting;
        } else if (this.isSubmitting || this.interaction.kind !== "viewing") {
            approve.disabled = true;
        } else if (action.kind !== "approve") {
            approve.disabled = false;
        } else if (!hasApprovalAction(state, "approve")) {
            approve.disabled = true;
        } else if (state.review.kind === "accountSelection") {
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
        this.renderTransactionNotice(review.notice);
        const sliderState = review.slider && review.slider.visible ? review.slider : null;
        setHidden("tx-slider-row", !sliderState);
        if (sliderState) {
            const slider = document.getElementById("tx-slider");
            const firstFeeLine = feeLines.children[0]?.textContent ||
                localized("calculating", "Calculating...");
            slider.max = sliderState.maximum || 200;
            slider.value = this.interaction.kind === "dragging"
                ? this.interaction.gesture.value : sliderState.position ?? 100;
            slider.setAttribute("aria-valuetext", firstFeeLine);
        }

        setOptionalText("tx-data", "tx-data-details", review.dataInterpretation);

        const canApplyEdits = hasApprovalAction(state, "editTransaction");
        if (canApplyEdits || this.editorDraft) {
            show("tx-editor");
            this.populateEditor(state);
        } else {
            hide("tx-editor");
        }
    }

    renderTransactionNotice(notice) {
        setHidden("tx-notice", !notice);
        if (!notice) { return; }
        setText("tx-notice-title", notice.title);
        setOptionalText("tx-notice-message", "tx-notice-message", notice.message);
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

    async approveCurrent() {
        if (!this.isActive || this.isSubmitting || !["viewing", "failed"].includes(this.interaction.kind)) { return; }
        const action = this.primaryAction(this.state);
        if (action.kind === "retryApproval") {
            await this.retry();
            return;
        }
        if (!this.state) { return; }
        if (action.kind === "retryTransaction") {
            await this.retryTransaction();
            return;
        }
        if (action.kind === "edit") {
            this.openEditor();
            if (this.editorDraft) {
                document.getElementById(this.editorDraft.usesEIP1559 ? "edit-max-priority" : "edit-gas-price").focus();
            }
            return;
        }
        if (action.kind === "refresh") {
            document.getElementById("button-approve").disabled = true;
            await this.readState();
            return;
        }
        const payload = {};
        if (this.state.review?.kind === "accountSelection") {
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
        if (this.isSubmitting || this.interaction.kind !== "viewing" || !this.allows("editTransaction")) {
            this.syncEditor();
            return;
        }
        this.changeInteraction(this.editingInteraction(this.state));
    }

    editingInteraction(state) {
        const editor = state.review.editor;
        return {kind: "editing", draft: {
            reviewToken: state.review.reviewToken,
            usesEIP1559: editor.usesEIP1559,
            values: transactionEditorValues(editor),
            error: null,
        }};
    }

    editorToggled() {
        if (!this.isActive) { return; }
        const wantsOpen = document.getElementById("tx-editor").open;
        if (this.isSubmitting) {
            this.syncEditor();
        } else if (wantsOpen) {
            this.openEditor();
        } else if (this.interaction.kind === "editing") {
            this.changeInteraction({kind: "viewing"});
        } else {
            this.syncEditor();
        }
    }

    editField(name, value) {
        if (!this.isActive || this.isSubmitting || this.interaction.kind !== "editing" ||
            !Object.hasOwn(this.interaction.draft.values, name)) { return; }
        this.interaction.draft.values[name] = value;
    }

    beginSliderInteraction() {
        const reviewToken = this.state?.review?.reviewToken;
        if (this.isSubmitting || !this.allows("setTransactionSpeed") || this.interaction.kind !== "viewing" ||
            !isRequestToken(reviewToken)) { return false; }
        ignoreSliderUntilRelease = false;
        this.changeInteraction({kind: "dragging", gesture: {
            reviewToken, value: Number(document.getElementById("tx-slider").value),
        }});
        return true;
    }

    updateSliderValue() {
        if (this.isActive && !this.isSubmitting && this.interaction.kind === "dragging") {
            this.interaction.gesture.value = Number(document.getElementById("tx-slider").value);
        }
    }

    finishSliderInteraction(interaction) {
        if (!this.isActive || this.isSubmitting || this.interaction.kind !== "dragging") { return null; }
        this.updateSliderValue();
        const gesture = this.interaction.gesture;
        this.interaction = {kind: "viewing"};
        return this.setSpeed({interaction, value: gesture.value}, gesture.reviewToken);
    }

    async applyEdits() { await this.applyEditor(false); }
    async applySuggested() { await this.applyEditor(true); }

    async applyEditor(suggested) {
        if (this.isSubmitting || !this.allows("editTransaction") || this.interaction.kind !== "editing") { return; }
        const draft = this.interaction.draft;
        const payload = suggested ? {mode: "suggested"} : {mode: "custom", ...draft.values};
        const operation = this.beginCommand("edits");
        const outcome = await this.sendCommand({subject: "applyTransactionEdits", payload, reviewToken: draft.reviewToken});
        if (!this.ownsCommand(operation)) { return; }
        const reply = this.acceptReply(outcome);
        if (!reply) { return; }
        const state = reply.approval;
        const preservesDraft = state.review?.kind === "sendTransaction" &&
            hasApprovalAction(state, "editTransaction") &&
            state.review.editor.usesEIP1559 === draft.usesEIP1559;
        let next = {kind: "viewing"};
        if (preservesDraft && (reply.status === "ignored" || reply.editsError)) {
            draft.reviewToken = state.review.reviewToken;
            draft.error = reply.status === "ignored" ? "reviewChanged" : "invalidValues";
            next = {kind: "editing", draft};
        }
        this.finishCommand(operation, state, next);
    }

    renderTransportFailure() {
        this.presentation.lastStateJSON = null;
        this.renderState({
            id: this.request.id,
            state: "error",
            actions: ["retry"],
            host: this.state?.host,
            error: localized("failedToLoad", "Failed to load"),
        });
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
    reviewToken
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
    const reply = decodeWireMessage("WorkflowProbeReply", probe.response);
    if (reply?.nonce === nonce) {
        return reply.buildVersion === BUILD_VERSION ? null : tab;
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
    return state.review?.kind === "accountSelection" &&
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
            workflowVersion: WORKFLOW_VERSION,
        });
    } catch {
        return "failure";
    }
    const outcome = await settleExtensionMessage(pending, RESPONSE_DELIVERY_TIMEOUT);
    if (outcome.status !== "response") { return "failure"; }
    const reply = decodeWireMessage("RuntimeApplyCompletedReply", outcome.response);
    if (reply?.applied === true) { return "applied"; }
    if (reply?.id === request.id && reply.missing === true) { return "missing"; }
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
        if (popupQueue.currentRequest?.isActive && !popupQueue.currentRequest.isSubmitting &&
            popupQueue.currentRequest.interaction.kind === "viewing") {
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
        if (popupQueue.currentRequest?.interaction.kind !== "dragging") {
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
