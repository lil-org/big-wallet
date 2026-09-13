
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
const APPROVAL_ACTIONS = new Set([
    "approve", "reject", "retry", "editTransaction",
    "setTransactionSpeed", "resolveApprovalAlert",
]);
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
    idleGeneration: 0,
    lastRefreshFailed: false,
    privateBrowsing: extensionPrivateBrowsing(),
    refreshGeneration: 0,
    refreshInFlight: null,
    refreshRequested: false,
    refreshTimer: null,
    snapshotStatus: "unknown",
    updateRecoveryTab: null,
};
let currentRequestController = null;
let popupStrings = {};
let ignoreSliderUntilRelease = false;

const NATIVE_MESSAGE_CANCELLED = Symbol("nativeMessageCancelled");
const nativeChannels = { read: Promise.resolve(), action: Promise.resolve() };
let unresolvedOpenAppCall = null;

class PopupRequestController {
    constructor(request) {
        this.request = request;
        this.state = null;
        this.phase = "loading";
        this.responseEpoch = 0;
        this.completion = null;
        this.mutation = null;
        this.scheduledRead = null;
        this.stateReadFlight = null;
        this.refreshDelay = TRANSACTION_REFRESH_INTERVAL;
        this.tickets = new Set();
        this.presentation = {
            accounts: null,
            chainId: null,
            networksKey: null,
            cluster: null,
            lastStateJSON: null,
            alertKey: null,
            alertReturnFocus: null,
        };
        this.transaction = {
            sliderDragging: false,
            sliderRequest: null,
            sliderReviewToken: null,
            activeCommand: null,
            generation: 0,
            lastEditorRequestKey: null,
            editorDirty: false,
        };
    }

    get isActive() {
        return currentRequestController === this &&
            this.phase !== "disposed" && this.phase !== "reconciling" &&
            sameRequest(this.request, queueTab.items[queueTab.index]);
    }

    requestFor(value) {
        if (!this.isActive) { return null; }
        return typeof value === "undefined" || value === this.request.id ||
            sameRequest(value, this.request) ? this.request : null;
    }

    isCurrentRequest(request) {
        return this.isActive && sameRequest(request, this.request);
    }

    start() {
        if (!this.isActive) { return; }
        show("working-overlay");
        setText("request-title", "");
        setText("request-host", this.request.host);
        hide("request-favicon");
        hide("request-error");
        for (const section of ["accounts", "message", "transaction", "chain"]) {
            hide("section-" + section);
        }
        document.getElementById("tx-editor").open = false;
        return this.readState();
    }

    dispose() {
        if (this.phase === "disposed") { return; }
        this.phase = "disposed";
        this.invalidateOperations();
        this.closeAlert(false);
    }

    invalidateOperations() {
        this.responseEpoch += 1;
        this.reconcileScheduling();
        for (const ticket of this.tickets) {
            cancelNativeMessageTicket(ticket);
        }
        this.discardSliderCommands(this.request);
    }

    async dispatch(kind, subject, payload, options = {}, ticketOwner = null) {
        if (!this.isActive) { return {status: "cancelled"}; }
        const ticket = scheduleNativeMessage(
            kind,
            subject,
            this.request.id,
            payload,
            this.request.requestToken,
            {...options, isValid: () => this.isActive &&
                (!options.isValid || options.isValid())}
        );
        this.tickets.add(ticket);
        if (ticketOwner) { ticketOwner.nativeTicket = ticket; }
        try {
            return await ticket.result;
        } finally {
            this.tickets.delete(ticket);
        }
    }

    closeAlert(restoreFocus) {
        if (currentRequestController !== this) { return; }
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

    get followUpTimer() {
        return this.scheduledRead?.timer ?? null;
    }

    get followUpMode() {
        if (!this.isActive || this.phase === "submitting" || this.stateReadFlight) {
            return null;
        }
        if (this.phase === "following" || shouldPollApprovalState(this.state)) {
            return "poll";
        }
        return this.state?.state === "review" &&
            this.state.review?.kind === "sendTransaction" ? "refresh" : null;
    }

    reconcileScheduling() {
        const mode = this.followUpMode;
        const delay = mode === "poll" ? APPROVAL_POLL_INTERVAL : this.refreshDelay;
        const current = this.scheduledRead;
        if (current && current.mode === mode && current.delay === delay &&
            current.epoch === this.responseEpoch) { return; }
        if (current) {
            clearTimeout(current.timer);
            this.scheduledRead = null;
        }
        if (mode === null) { return; }
        const scheduled = {mode, delay, epoch: this.responseEpoch, timer: null};
        scheduled.timer = setTimeout(() => {
            if (this.scheduledRead !== scheduled) { return; }
            this.scheduledRead = null;
            if (this.responseEpoch !== scheduled.epoch || this.followUpMode !== mode) {
                this.reconcileScheduling();
                return;
            }
            void this.readState({refresh: mode === "refresh"});
        }, delay);
        this.scheduledRead = scheduled;
    }

    resetTransactionRefreshBackoff() {
        this.refreshDelay = TRANSACTION_REFRESH_INTERVAL;
    }

    updateTransactionRefreshBackoff(state, unchanged) {
        if (!unchanged || !STABLE_TRANSACTION_PHASES.has(state.review?.phase)) {
            this.resetTransactionRefreshBackoff();
            return;
        }
        this.refreshDelay = Math.min(
            this.refreshDelay * 2,
            TRANSACTION_REFRESH_MAX_INTERVAL
        );
    }

    async readState({refresh = false} = {}) {
        if (!this.isActive || this.phase === "submitting") { return; }
        const epoch = this.responseEpoch;
        if (this.stateReadFlight) {
            const flight = this.stateReadFlight;
            if (flight.epoch === epoch) {
                if (!refresh) { flight.refresh = false; }
                return flight.result;
            }
            await flight.result;
            if (epoch !== this.responseEpoch) { return; }
            return this.readState({refresh});
        }
        const flight = {epoch, refresh, result: null};
        this.stateReadFlight = flight;
        this.reconcileScheduling();
        flight.result = (async () => {
            try {
                const state = await this.requestState(
                    "getApprovalState", undefined, this.request, "approval", null,
                    () => flight.epoch === this.responseEpoch && this.phase !== "submitting"
                );
                if (!this.acceptResponse(state, flight.epoch)) { return; }
                if (flight.refresh && this.state) {
                    const unchanged = JSON.stringify(state) === this.presentation.lastStateJSON;
                    this.state = state;
                    this.phase = shouldPollApprovalState(state) ? "following" : "displaying";
                    if (!state.review || !this.transaction.sliderDragging &&
                        !this.transaction.activeCommand) {
                        if (!unchanged) {
                            this.renderState(state);
                        } else if (state.review?.slider?.visible) {
                            document.getElementById("tx-slider").value = state.review.slider.position;
                        }
                    }
                    this.updateTransactionRefreshBackoff(state, unchanged);
                } else {
                    this.resetTransactionRefreshBackoff();
                    this.adoptState(state);
                }
                return state;
            } finally {
                if (this.stateReadFlight === flight) { this.stateReadFlight = null; }
                this.reconcileScheduling();
            }
        })();
        return flight.result;
    }

    renderState(state) {
        if (!this.isActive) { return; }
        this.presentation.lastStateJSON = JSON.stringify(state);
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
            this.discardSliderCommands(this.request);
            document.getElementById("tx-slider").disabled = true;
            document.getElementById("editor-apply").disabled = true;
            document.getElementById("editor-suggested").disabled = true;
            if (isBusy) {
                document.getElementById("screen-request").inert = true;
                return;
            }
            this.transaction.editorDirty = false;
            document.getElementById("tx-editor").open = false;
            hide("tx-editor");
            hide("edits-error");
        }

        setText("request-title", state.review?.title || "");
        setText("request-host", state.host || "");
        const favicon = document.getElementById("request-favicon");
        if (state.review?.iconURL && favicon.src !== state.review.iconURL) {
            favicon.src = state.review.iconURL;
        }
        setHidden("request-favicon", !state.review?.iconURL);
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
        this.updateApproveEnabled(state);
        this.renderAlertIfNeeded(state);
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
                if (!this.isActive) { return; }
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
        if (hasApprovalAction(state, "retry") || shouldRefreshAccountSelection(state)) {
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
            if (!this.transaction.sliderDragging) {
                slider.value = sliderState.position ?? 100;
            }
            slider.disabled = !hasApprovalAction(state, "setTransactionSpeed");
            slider.setAttribute("aria-valuetext", firstFeeLine);
        }

        setOptionalText("tx-data", "tx-data-details", review.dataInterpretation);

        const canApplyEdits = hasApprovalAction(state, "editTransaction");
        document.getElementById("editor-apply").disabled = !canApplyEdits;
        document.getElementById("editor-suggested").disabled = !canApplyEdits;
        const editorDetails = document.getElementById("tx-editor");
        if (canApplyEdits || editorDetails.open) {
            show("tx-editor");
            // An open editor keeps whatever the user typed, but until they type it follows the fee:
            // applying fields left over from before a slider move would silently undo that move.
            if (!this.transaction.editorDirty) {
                this.populateEditor(state);
            }
            const request = this.request;
            const requestToken = request && request.id === state.id
                ? request.requestToken || ""
                : "";
            const editorRequestKey = typeof review.editorRequestToken === "number"
                ? requestToken + ":" + state.id + ":" + review.editorRequestToken
                : null;
            if (editorRequestKey !== null && editorRequestKey !== this.transaction.lastEditorRequestKey) {
                this.transaction.lastEditorRequestKey = editorRequestKey;
                editorDetails.open = true;
            }
        } else {
            hide("tx-editor");
        }
    }

    populateEditor(state) {
        const review = state.review;
        this.transaction.editorDirty = false;
        const editor = review.editor || {};
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

    async approveCurrent() {
        if (!this.isActive || this.phase === "submitting") { return; }
        if (!this.state) { return; }
        if (hasApprovalAction(this.state, "retry")) {
            await this.retryApproval();
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
        await this.submitCurrentDecision("approveRequest", payload);
    }

    async retryApproval() {
        if (!this.isActive || this.phase === "submitting" ||
            !hasApprovalAction(this.state, "retry")) { return; }
        const request = this.request;
        this.responseEpoch += 1;
        const generation = this.responseEpoch;
        this.phase = "submitting";
        this.reconcileScheduling();
        document.getElementById("button-approve").disabled = true;
        show("working-overlay");
        const state = await this.requestState(
            "retryApproval", undefined, request, "action", null,
            () => this.responseEpoch === generation &&
                hasApprovalAction(this.state, "retry"),
            undefined
        );
        if (!this.acceptResponse(state, generation)) { return; }
        this.resetTransactionRefreshBackoff();
        this.adoptState(state);
    }

    async rejectCurrent() {
        await this.submitCurrentDecision("rejectRequest");
    }

    async submitCurrentDecision(subject, payload) {
        if (!this.isActive || this.phase === "submitting") { return; }
        const request = this.request;
        const initialState = this.state;
        if (!request || !canSubmitDecision(subject, initialState)) { return; }
        const rerenderCurrentReview = () => {
            const currentState = this.state;
            if (this.isCurrentRequest(request) && currentState?.state === "review") {
                this.renderState(currentState);
            }
        };
        if (subject === "approveRequest") {
            this.finishSliderDragForDecision(request);
            if (!await this.waitForSliderCommands(request)) { return; }
        } else {
            this.discardSliderCommands(request);
        }
        if (!this.isActive || this.phase === "submitting") { return; }
        const state = this.state;
        if (!this.isCurrentRequest(request) || !canSubmitDecision(subject, state)) {
            rerenderCurrentReview();
            return;
        }
        const reviewToken = subject === "approveRequest"
            ? state.review?.reviewToken
            : undefined;
        const remainsCurrent = () => this.isCurrentRequest(request) &&
            canSubmitDecision(subject, this.state) &&
            (subject !== "approveRequest" ||
                this.state?.review?.reviewToken === reviewToken);
        show("working-overlay");
        let decisionPayload = payload;
        if (subject === "approveRequest") {
            decisionPayload = {...(isRecord(payload) ? payload : {})};
            delete decisionPayload.revisions;
            delete decisionPayload.password;
        }
        this.responseEpoch += 1;
        this.phase = "submitting";
        this.reconcileScheduling();
        const outcome = await this.dispatch(
            "action", subject, decisionPayload,
            {isValid: remainsCurrent, reviewToken, approvalRequest: request}
        );
        if (!this.isCurrentRequest(request)) { return; }
        if (outcome.status === "cancelled") {
            this.phase = "displaying";
            rerenderCurrentReview();
            this.reconcileScheduling();
            return;
        }
        if (outcome.status !== "response" || !isRecord(outcome.response)) {
            this.failClosedApprovalState(request);
            return;
        }
        this.phase = "following";
        this.reconcileScheduling();
    }

    reconcileMissingRequest(value) {
        if (this.completion !== null) { return this.completion; }
        if (!this.requestFor(value)) { return Promise.resolve(); }
        this.phase = "reconciling";
        this.invalidateOperations();
        this.closeAlert(false);
        this.completion = closeIfNothingIsLeft();
        return this.completion;
    }

    async requestState(
        subject,
        payload,
        value,
        nativeCallKind = "approval",
        ticketOwner = null,
        remainsValid = null,
        reviewToken
    ) {
        if (!this.requestFor(value)) { return null; }
        const options = {isValid: remainsValid};
        if (subject === "retryApproval" || typeof reviewToken !== "undefined") {
            options.reviewToken = reviewToken;
        }
        const outcome = await this.dispatch(
            nativeCallKind, subject, payload, options, ticketOwner
        );
        if (outcome.status === "cancelled") { return NATIVE_MESSAGE_CANCELLED; }
        return outcome.status === "response"
            ? normalizeApprovalImages(outcome.response)
            : null;
    }

    acceptResponse(state, generation = this.responseEpoch) {
        if (!this.isActive || generation !== this.responseEpoch ||
            state === NATIVE_MESSAGE_CANCELLED) { return false; }
        if (!isRenderableApprovalState(state, this.request)) {
            this.failClosedApprovalState(this.request);
            return false;
        }
        return !this.handleMissingState(state, this.request);
    }

    async mutateState(subject, payload, value, reviewToken) {
        if (!this.isActive || this.phase === "submitting") { return null; }
        const request = this.requestFor(value);
        if (!request || !this.isCurrentRequest(request)) { return null; }
        const action = subject === "applyTransactionEdits" ? "editTransaction" : subject;
        if (!hasApprovalAction(this.state, action)) { return null; }
        const isRichMutation = subject !== "setTransactionSpeed";
        if (isRichMutation && sameRequest(this.mutation?.request, request)) {
            return null;
        }
        const mutation = { request: request, subject: subject };
        if (isRichMutation) {
            this.mutation = mutation;
        }
        try {
            if (isRichMutation && !await this.waitForSliderCommands(request)) { return null; }
            if (!this.isActive || this.phase === "submitting") { return null; }
            if (!this.isCurrentRequest(request)) { return null; }
            if (isRichMutation && this.mutation !== mutation) {
                return null;
            }
            if (!hasApprovalAction(this.state, action)) { return null; }
            this.responseEpoch += 1;
            this.resetTransactionRefreshBackoff();
            const generation = this.responseEpoch;
            const ticketOwner = isRichMutation ? mutation : this.transaction.activeCommand;
            const state = await this.requestState(
                subject,
                payload,
                request,
                "mutation",
                ticketOwner,
                () => generation === this.responseEpoch &&
                    hasApprovalAction(this.state, action) &&
                    (typeof reviewToken === "undefined" ||
                        this.state?.review?.reviewToken === reviewToken),
                reviewToken
            );
            if (generation !== this.responseEpoch) { return null; }
            if (!this.isCurrentRequest(request)) { return null; }
            if (state === NATIVE_MESSAGE_CANCELLED) { return null; }
            if (!isRenderableApprovalState(state, request)) {
                if ((subject === "resolveApprovalAlert" ||
                    subject === "setTransactionSpeed") && isRecord(state) &&
                    state.status === "ignored" && Object.keys(state).length === 1) {
                    return null;
                }
                this.failClosedApprovalState(request);
                return null;
            }
            if (this.handleMissingState(state, request)) { return null; }
            return state;
        } finally {
            if (this.mutation === mutation) {
                this.mutation = null;
            }
        }
    }

    handleMissingState(state, value) {
        if (!state || state.state !== "missing") { return false; }
        const request = this.requestFor(value);
        if (!request || !this.isCurrentRequest(request)) { return true; }
        void this.reconcileMissingRequest(request);
        return true;
    }

    failClosedApprovalState(request) {
        if (!request || !this.isCurrentRequest(request)) { return; }
        this.responseEpoch += 1;
        const previous = this.state || {};
        this.presentation.lastStateJSON = null;
        this.resetTransactionRefreshBackoff();
        this.closeAlert(false);
        document.getElementById("tx-editor").open = false;
        this.transaction.editorDirty = false;
        hide("edits-error");
        document.getElementById("button-approve").disabled = true;
        this.state = {
            id: request.id,
            state: "error",
            actions: ["retry"],
            ...(typeof previous.host === "string" && previous.host.length > 0
                ? {host: previous.host}
                : {}),
            error: localized("failedToLoad", "Failed to load"),
        };
        this.phase = "displaying";
        this.renderState(this.state);
        this.reconcileScheduling();
    }

    adoptState(state) {
        if (!this.isActive || !state?.state) { return; }
        this.state = state;
        this.phase = shouldPollApprovalState(state) ? "following" : "displaying";
        this.renderState(state);
        this.reconcileScheduling();
    }

    async sendSliderEvent(
        interaction,
        value,
        request,
        commandGeneration = this.transaction.generation,
        reviewToken = this.state?.review?.reviewToken
    ) {
        const capturedRequest = this.requestFor(request);
        if (!capturedRequest || !this.isCurrentRequest(capturedRequest)) { return false; }
        let refreshed = false;
        const refreshAuthoritativeState = async () => {
            if (!refreshed && commandGeneration === this.transaction.generation &&
                this.isCurrentRequest(capturedRequest)) {
                refreshed = true;
                await this.readState();
            }
            return false;
        };
        if (!isRequestToken(reviewToken) ||
            this.state?.review?.reviewToken !== reviewToken) {
            return await refreshAuthoritativeState();
        }
        const state = await this.mutateState(
            "setTransactionSpeed",
            {value, interaction},
            capturedRequest,
            reviewToken
        );
        if (commandGeneration !== this.transaction.generation ||
            !this.isCurrentRequest(capturedRequest)) {
            return false;
        }
        if (!state) { return await refreshAuthoritativeState(); }
        this.adoptState(state);
        return true;
    }

    beginSliderInteraction(
        request,
        reviewToken = this.state?.review?.reviewToken
    ) {
        const capturedRequest = this.requestFor(request);
        if (this.transaction.activeCommand ||
            this.transaction.sliderDragging ||
            !capturedRequest || !this.isCurrentRequest(capturedRequest) ||
            !isRequestToken(reviewToken)) {
            return false;
        }
        ignoreSliderUntilRelease = false;
        this.transaction.sliderDragging = true;
        this.transaction.sliderRequest = capturedRequest;
        this.transaction.sliderReviewToken = reviewToken;
        return true;
    }

    startSliderCommand(
        interaction,
        value,
        request,
        reviewToken = this.state?.review?.reviewToken
    ) {
        const capturedRequest = this.requestFor(request);
        if (!capturedRequest || !this.isCurrentRequest(capturedRequest) ||
            !isRequestToken(reviewToken) || this.transaction.activeCommand) {
            return null;
        }
        let resolveCompletion;
        const command = {
            commandGeneration: this.transaction.generation,
            completion: new Promise(resolve => { resolveCompletion = resolve; }),
            interaction: interaction,
            request: capturedRequest,
            reviewToken: reviewToken,
            resolveCompletion: null,
            value: value,
        };
        command.resolveCompletion = resolveCompletion;
        this.transaction.activeCommand = command;
        document.getElementById("tx-slider").disabled = true;
        void (async () => {
            let succeeded = false;
            try {
                succeeded = await this.sendSliderEvent(
                    command.interaction,
                    command.value,
                    command.request,
                    command.commandGeneration,
                    command.reviewToken
                );
            } finally {
                if (this.transaction.activeCommand === command) {
                    this.transaction.activeCommand = null;
                }
                finishSliderCommand(command, succeeded);
            }
        })();
        return command.completion;
    }

    async waitForSliderCommands(request) {
        const generation = this.transaction.generation;
        if (this.transaction.sliderDragging &&
            sameRequest(this.transaction.sliderRequest, request)) {
            return false;
        }
        const command = this.transaction.activeCommand;
        if (!command) { return true; }
        if (command.commandGeneration !== generation ||
            !sameRequest(command.request, request)) { return false; }
        const succeeded = await command.completion;
        return succeeded === true && generation === this.transaction.generation &&
            this.isCurrentRequest(request);
    }

    discardSliderCommands(request) {
        this.transaction.generation += 1;
        const command = this.transaction.activeCommand;
        if (sameRequest(command?.request, request)) {
            cancelNativeMessageTicket(command.nativeTicket);
            finishSliderCommand(command, false);
            this.transaction.activeCommand = null;
        }
        if (sameRequest(this.transaction.sliderRequest, request)) {
            ignoreSliderUntilRelease = true;
            this.transaction.sliderDragging = false;
            this.transaction.sliderRequest = null;
            this.transaction.sliderReviewToken = null;
        }
    }

    finishSliderInteraction(interaction, request) {
        if (!this.transaction.sliderDragging ||
            (request && !sameRequest(this.transaction.sliderRequest, request))) {
            return null;
        }
        const capturedRequest = this.transaction.sliderRequest;
        const value = Number(document.getElementById("tx-slider").value);
        const reviewToken = this.transaction.sliderReviewToken;
        this.transaction.sliderDragging = false;
        this.transaction.sliderRequest = null;
        this.transaction.sliderReviewToken = null;
        return this.startSliderCommand(
            interaction,
            value,
            capturedRequest,
            reviewToken
        );
    }

    finishSliderDragForDecision(request) {
        if (!this.transaction.sliderDragging ||
            !sameRequest(this.transaction.sliderRequest, request)) { return; }
        ignoreSliderUntilRelease = true;
        this.finishSliderInteraction("ended", request);
    }

    async applyEdits() {
        if (!this.isActive) { return; }
        if (!hasApprovalAction(this.state, "editTransaction")) { return; }
        const editor = (this.state.review?.editor || {});
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
        this.handleTransactionEditResult(await this.mutateState("applyTransactionEdits", payload));
    }

    async applySuggested() {
        if (!this.isActive) { return; }
        if (!hasApprovalAction(this.state, "editTransaction")) { return; }
        this.handleTransactionEditResult(await this.mutateState(
            "applyTransactionEdits",
            { mode: "suggested" }
        ));
    }

    handleTransactionEditResult(state) {
        if (!this.isActive) { return; }
        if (state && state.editsError) {
            show("edits-error");
        } else {
            this.closeEditorAndAdopt(state);
        }
        this.reconcileScheduling();
    }

    closeEditorAndAdopt(state) {
        if (!this.isActive) { return; }
        if (!state || !state.state) { return; }
        this.transaction.editorDirty = false;
        hide("edits-error");
        document.getElementById("tx-editor").open = false;
        this.adoptState(state);
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
                const state = await this.mutateState("resolveApprovalAlert", {
                    action: action.action,
                }, undefined, reviewToken);
                if (this.state?.review?.reviewToken !== reviewToken) { return; }
                this.adoptState(state);
            });
            buttons.appendChild(button);
        }
        document.getElementById("screen-request").inert = true;
        show("alert-overlay");
        const focusTarget = buttons.children[0] || document.getElementById("alert-box");
        focusTarget.focus();
    }
}

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
                : currentRequestController?.state?.review?.reviewToken
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
    if (!currentRequest || currentRequestController?.phase === "reconciling") {
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
    currentRequestController?.dispose();
    currentRequestController = null;
    queueTab.idleGeneration += 1;
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
    const generation = ++queueTab.idleGeneration;
    currentRequestController?.dispose();
    currentRequestController = null;
    document.getElementById("idle-check-status").disabled = false;
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
    if (generation !== queueTab.idleGeneration) { return; }
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
    currentRequestController?.dispose();
    const controller = new PopupRequestController(request);
    currentRequestController = controller;
    controller.start();
}

function sameRequest(left, right) {
    return !!left && !!right &&
        left.id === right.id &&
        left.requestToken === right.requestToken;
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

function normalizeApprovalImages(state) {
    if (!isRecord(state?.review) || !APPROVAL_KINDS.has(state.review.kind)) { return state; }

    function withoutInvalidImage(record, key) {
        if (!isRecord(record) || isOptionalString(record[key])) { return record; }
        const copy = {...record};
        delete copy[key];
        return copy;
    }

    let review = withoutInvalidImage(state.review, "iconURL");
    const account = withoutInvalidImage(review.account, "icon");
    if (account !== review.account) {
        review = {...review, account};
    }
    if (Array.isArray(review.accounts)) {
        const accounts = review.accounts.map(account => withoutInvalidImage(account, "icon"));
        if (accounts.some((account, index) => account !== review.accounts[index])) {
            review = {...review, accounts};
        }
    }
    return review === state.review ? state : {...state, review};
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
    return (typeof state.host === "undefined" ||
            typeof state.host === "string" && state.host.length > 0) &&
        isOptionalString(state.error) &&
        isOptionalBoolean(state.editsError);
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

function isSelectionState(review) {
    if (!Array.isArray(review.accounts) || !review.accounts.every(account =>
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
    if (!hasUniqueValues(review.accounts, accountIdentityKey) ||
        !hasUniqueValues(review.accounts.filter(account => account.isSelected), account => account.coin)) {
        return false;
    }
    if (typeof review.networks !== "undefined" &&
        (!Array.isArray(review.networks) || !review.networks.every(network =>
            isRecord(network) &&
            isCanonicalEthereumChainId(network.chainId) &&
            typeof network.name === "string" &&
            typeof network.isSelected === "boolean" &&
            isOptionalBoolean(network.isCustom)
        ) ||
        !hasUniqueValues(review.networks, network => network.chainId) ||
        review.networks.filter(network => network.isSelected).length > 1)) {
        return false;
    }
    return typeof review.canSelectNetwork === "boolean" &&
        typeof review.allowsEmptySelection === "boolean" &&
        isOptionalString(review.emptyMessage) &&
        (!review.accounts.some(account => account.coin === "ethereum") ||
            review.canSelectNetwork) &&
        (!review.canSelectNetwork || Array.isArray(review.networks));
}

function isSignMessageState(review) {
    if (!isDisplayAccount(review.account) || typeof review.meta !== "string") {
        return false;
    }
    const hasClusters = typeof review.clusters !== "undefined";
    const hasRequirement = typeof review.requiresClusterSelection !== "undefined";
    if (hasClusters !== hasRequirement) {
        return false;
    }
    if (!hasClusters) {
        return true;
    }
    if (typeof review.requiresClusterSelection !== "boolean" ||
        !Array.isArray(review.clusters) || review.clusters.length === 0 ||
        !review.clusters.every(cluster =>
            isRecord(cluster) &&
            SOLANA_CLUSTER_VALUES.has(cluster.value) &&
            typeof cluster.label === "string" &&
            typeof cluster.isSelected === "boolean"
        ) ||
        !hasUniqueValues(review.clusters, cluster => cluster.value)) {
        return false;
    }
    const selectedCount = review.clusters.filter(cluster => cluster.isSelected).length;
    return review.requiresClusterSelection ? selectedCount === 0 : selectedCount === 1;
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

function isTransactionState(review) {
    return isDisplayAccount(review.account) &&
        typeof review.networkName === "string" &&
        Array.isArray(review.feeLines) &&
        review.feeLines.every(line => typeof line === "string") &&
        TRANSACTION_PHASES.has(review.phase) &&
        isOptionalString(review.balance) &&
        isOptionalString(review.valueLine) &&
        isOptionalString(review.dataInterpretation) &&
        (typeof review.editorRequestToken === "undefined" ||
            Number.isSafeInteger(review.editorRequestToken)) &&
        isRecord(review.slider) &&
        typeof review.slider.visible === "boolean" &&
        typeof review.slider.position === "number" &&
        Number.isFinite(review.slider.position) &&
        typeof review.slider.maximum === "number" &&
        Number.isFinite(review.slider.maximum) &&
        isTransactionEditor(review.editor);
}

function isRenderableApprovalState(state, request) {
    if (!isApprovalStateEnvelope(state, request) ||
        !hasValidOptionalApprovalFields(state) ||
        !Array.isArray(state.actions) ||
        !state.actions.every(action => APPROVAL_ACTIONS.has(action)) ||
        !hasUniqueValues(state.actions, action => action) ||
        !Object.keys(state).every(key => [
            "id", "state", "actions", "host", "error", "review", "editsError",
        ].includes(key))) {
        return false;
    }
    if (state.state !== "review") {
        return typeof state.review === "undefined" &&
            (state.state === "error"
                ? typeof state.error === "string" && state.actions.length === 1 &&
                    (hasApprovalAction(state, "retry") || hasApprovalAction(state, "reject"))
                : state.actions.length === 0);
    }
    const review = state.review;
    if (!isRecord(review) || !APPROVAL_KINDS.has(review.kind) ||
        !isRequestToken(review.reviewToken) ||
        typeof review.title !== "string" ||
        typeof state.host !== "string" || state.host.length === 0 ||
        !isOptionalString(review.iconURL) ||
        !isOptionalString(review.primaryTitle) || !isAlert(review.alert) ||
        hasApprovalAction(state, "retry") ||
        (review.kind !== "sendTransaction" && state.actions.some(action =>
            action !== "approve" && action !== "reject"))) {
        return false;
    }
    switch (review.kind) {
        case "selectAccount":
        case "switchAccount":
            return typeof review.alert === "undefined" && isSelectionState(review);
        case "signMessage":
            return typeof review.alert === "undefined" && isSignMessageState(review);
        case "sendTransaction":
            return isTransactionState(review);
        case "addChain":
            return typeof review.alert === "undefined" &&
                typeof review.chainName === "string" &&
                typeof review.rpcURL === "string";
    }
    return false;
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
    return accountIdentityKey(left) === accountIdentityKey(right);
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

// The queue is a snapshot taken when the popup opened, so it is asked again before closing:
// a request that arrived in the meantime gets shown instead of being left behind. A fetch
// failure keeps the popup open too — an unreachable wallet does not mean the queue drained.
async function closeIfNothingIsLeft() {
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

function finishSliderCommand(command, succeeded) {
    if (!command?.resolveCompletion) { return; }
    const resolve = command.resolveCompletion;
    command.resolveCompletion = null;
    resolve(succeeded);
}

function isCurrentIdlePresentation(generation, tab) {
    return queueTab.idleGeneration === generation &&
        sameTab(queueTab.activeTab, tab) &&
        !currentRequestController &&
        !document.getElementById("screen-idle").classList.contains("hidden");
}

async function switchAccountFromIdle() {
    const button = document.getElementById("idle-switch-account");
    const tab = queueTab.activeTab;
    if (button.disabled || !tab || currentPrivateBrowsing()) { return; }
    const generation = queueTab.idleGeneration;
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
    if (!isCurrentIdlePresentation(generation, tab)) {
        requestPendingQueueRefresh();
        return;
    }
    if (outcome.status === "failure") {
        queueTab.contentScriptUnavailableTab = tab;
    } else if (outcome.status === "response" &&
        sameTab(queueTab.contentScriptUnavailableTab, tab)) {
        queueTab.contentScriptUnavailableTab = null;
    }
    const id = response?.id;
    const valid = Number.isSafeInteger(id) && (
        BigWalletBridgeWire.isManualSwitchAcknowledgement(
            response,
            id,
            tab.configurationKey
        ) ||
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
    const generation = queueTab.idleGeneration;
    const activeTab = queueTab.activeTab;
    button.disabled = true;
    const refreshGeneration = queueTab.refreshGeneration;
    const currentTab = await currentActiveTab();
    if (!isCurrentIdlePresentation(generation, activeTab)) { return; }
    const sameCurrentTab = sameUpdateRecoveryTab(currentTab, tab);
    const currentRecoveryTab = sameCurrentTab
        ? await updateRecoveryTabFor(currentTab)
        : null;
    if (!isCurrentIdlePresentation(generation, activeTab)) { return; }
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
    if (!isCurrentIdlePresentation(generation, activeTab)) { return; }
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
    document.getElementById("button-approve").addEventListener("click", () => currentRequestController?.approveCurrent());
    document.getElementById("button-reject").addEventListener("click", () => currentRequestController?.rejectCurrent());
    document.getElementById("idle-open-app").addEventListener("click", openBigWallet);
    document.getElementById("idle-switch-account").addEventListener("click", switchAccountFromIdle);
    document.getElementById("idle-check-status").addEventListener("click", refreshIdleStatus);
    document.getElementById("editor-apply").addEventListener("click", () => currentRequestController?.applyEdits());
    document.getElementById("editor-suggested").addEventListener("click", () => currentRequestController?.applySuggested());
    document.getElementById("network-select").addEventListener("change", () => {
        if (currentRequestController?.isActive) {
            currentRequestController.presentation.chainId = document.getElementById("network-select").value;
        }
    });
    for (const fieldId of ["edit-gas-price", "edit-max-priority", "edit-max-fee", "edit-nonce"]) {
        document.getElementById(fieldId).addEventListener("input", () => {
            if (currentRequestController?.isActive) {
                currentRequestController.transaction.editorDirty = true;
            }
        });
    }

    const slider = document.getElementById("tx-slider");
    slider.addEventListener("pointerdown", () => {
        currentRequestController?.beginSliderInteraction();
    });
    slider.addEventListener("input", () => {
        if (ignoreSliderUntilRelease) { return; }
        if (!currentRequestController?.transaction.sliderDragging) {
            currentRequestController?.beginSliderInteraction();
        }
    });
    const endDrag = interaction => {
        if (ignoreSliderUntilRelease) {
            ignoreSliderUntilRelease = false;
            return;
        }
        currentRequestController?.finishSliderInteraction(interaction);
    };
    slider.addEventListener("pointerup", () => { endDrag("ended"); });
    slider.addEventListener("pointercancel", () => {
        endDrag("cancelled");
    });
    slider.addEventListener("change", () => { endDrag("ended"); });

    boot();
});
