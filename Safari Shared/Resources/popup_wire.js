// ∅ 2026 lil org

(function (root, factory) {
    if (typeof module === "object" && module.exports) {
        module.exports = factory(require("./bridge_wire.js"));
    } else {
        root.BigWalletPopupWire = factory(root.BigWalletBridgeWire);
    }
})(typeof globalThis !== "undefined" ? globalThis : this, function (wire) {
    "use strict";

    const {
        WORKFLOW_POLICY, hasExactKeys, isCanonicalEthereumChainId,
        isPrivateToken, isProviderRevisions, isRecord, isRequestToken,
        isValidRequestId,
    } = wire;

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
    const ALERT_ACTIONS = new Set(["acknowledge", "retry", "edit", "cancel"]);

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
            !hasUniqueValues(state.actions, action => action)) {
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


    function fields(value, keys) {
        return Object.fromEntries(keys.filter(key => typeof value[key] !== "undefined")
            .map(key => [key, value[key]]));
    }

    function decodeQueue(raw) {
        const decoded = parsePendingResponse(raw);
        if (!decoded) { return null; }
        return {
            ...fields(decoded, ["layoutDirection", "strings"]),
            requests: decoded.requests.map(request => fields(request, [
                "id", "requestToken", "enqueueAttempt", "sequence", "host",
                "configurationKey", "provider", "revisions", "receivedAt",
            ])),
            completedResponses: decoded.completedResponses.map(response => fields(response, [
                "id", "host", "configurationKey", "requestToken", "revisions",
            ])),
        };
    }

    function decodeApprovalState(raw, expectedRequestID) {
        const state = normalizeApprovalImages(raw);
        if (!isRenderableApprovalState(state, {id: expectedRequestID})) { return null; }
        const decoded = fields(state, ["id", "state", "host", "error", "editsError"]);
        decoded.actions = state.actions.slice();
        if (!state.review) { return decoded; }
        const review = state.review;
        const output = fields(review, ["kind", "reviewToken", "title", "iconURL", "primaryTitle"]);
        const displayAccount = account => fields(account, ["name", "croppedAddress", "icon"]);
        switch (review.kind) {
            case "selectAccount":
            case "switchAccount":
                Object.assign(output, fields(review, ["canSelectNetwork", "allowsEmptySelection", "emptyMessage"]));
                output.accounts = review.accounts.map(account => ({
                    ...displayAccount(account),
                    ...fields(account, ["walletId", "coin", "address", "derivationPath", "isSelected"]),
                }));
                if (review.networks) {
                    output.networks = review.networks.map(network => fields(network, [
                        "chainId", "name", "isSelected", "isCustom",
                    ]));
                }
                break;
            case "signMessage":
                output.account = displayAccount(review.account);
                output.meta = review.meta;
                if (review.clusters) {
                    output.clusters = review.clusters.map(cluster => fields(cluster, ["value", "label", "isSelected"]));
                    output.requiresClusterSelection = review.requiresClusterSelection;
                }
                break;
            case "sendTransaction":
                output.account = displayAccount(review.account);
                Object.assign(output, fields(review, [
                    "networkName", "phase", "balance", "valueLine", "dataInterpretation", "editorRequestToken",
                ]));
                output.feeLines = review.feeLines.slice();
                output.slider = fields(review.slider, ["visible", "position", "maximum"]);
                output.editor = fields(review.editor, [
                    "usesEIP1559", "nonce", "gasPriceGwei", "maxPriorityFeePerGasGwei", "maxFeePerGasGwei",
                    "suggestedGasPriceGwei", "suggestedMaxPriorityFeePerGasGwei", "suggestedMaxFeePerGasGwei",
                ]);
                if (review.alert) {
                    output.alert = {
                        title: review.alert.title,
                        message: review.alert.message,
                        actions: review.alert.actions.map(action => fields(action, ["title", "action"])),
                    };
                }
                break;
            case "addChain":
                output.chainName = review.chainName;
                output.rpcURL = review.rpcURL;
                break;
        }
        decoded.review = output;
        return decoded;
    }

    function decodeCommandResult(raw) {
        return hasExactKeys(raw, ["status"]) &&
            ["ok", "ignored", "unavailable"].includes(raw.status)
            ? {status: raw.status} : null;
    }

    return Object.freeze({
        accountIdentityKey,
        decodeApprovalState,
        decodeCommandResult,
        decodeQueue,
    });
});
