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
        isPrivateToken, isRecord, isRequestToken,
        isValidRequestId,
    } = wire;

    const APPROVAL_STATES = new Set(["missing", "review", "authenticating", "working", "error"]);
    const APPROVAL_ACTIONS = new Set([
        "approve", "reject", "retry", "editTransaction",
        "setTransactionSpeed", "resolveApprovalAlert",
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

    function isOptionalString(value) {
        return typeof value === "undefined" || typeof value === "string";
    }

    function isOptionalBoolean(value) {
        return typeof value === "undefined" || typeof value === "boolean";
    }

    function definedFields(values) {
        return Object.fromEntries(Object.entries(values).filter(([, value]) => value !== undefined));
    }

    function decodeItems(values, decode) {
        if (!Array.isArray(values)) { return null; }
        const decoded = values.map(decode);
        return decoded.every(value => value !== null) ? decoded : null;
    }

    function hasUniqueValues(items, valueFor) {
        return new Set(items.map(valueFor)).size === items.length;
    }

    function accountIdentityKey(account) {
        return JSON.stringify([
            account.walletId,
            account.coin,
            account.coin === "ethereum" ? account.address.toLowerCase() : account.address,
            account.derivationPath,
        ]);
    }

    function decodePendingRequest(value) {
        if (!isRecord(value)) { return null; }
        const {id, requestToken, enqueueAttempt, sequence, host,
            configurationKey, provider, receivedAt} = value;
        if (!isValidRequestId(id) || !isRequestToken(requestToken) ||
            (enqueueAttempt !== undefined && !isPrivateToken(enqueueAttempt)) ||
            !Number.isSafeInteger(sequence) || sequence < 0 ||
            typeof host !== "string" || host.length === 0 ||
            typeof configurationKey !== "string" || configurationKey.length === 0 ||
            !["ethereum", "solana", "unknown"].includes(provider) ||
            !Number.isFinite(receivedAt)) {
            return null;
        }
        return definedFields({id, requestToken, enqueueAttempt, sequence, host,
            configurationKey, provider, receivedAt});
    }

    function decodeCompletedResponse(value) {
        if (!hasExactKeys(value, ["configurationKey", "host", "id", "requestToken"])) {
            return null;
        }
        const {id, host, configurationKey, requestToken} = value;
        if (!isValidRequestId(id) || !isRequestToken(requestToken) ||
            typeof host !== "string" || host.length === 0 ||
            typeof configurationKey !== "string" || configurationKey.length === 0) {
            return null;
        }
        return {id, host, configurationKey, requestToken};
    }

    function decodeQueue(value) {
        if (!isRecord(value)) { return null; }
        const {layoutDirection, strings} = value;
        if ((strings !== undefined && (!isRecord(strings) ||
                !Object.values(strings).every(value => typeof value === "string"))) ||
            (layoutDirection !== undefined && layoutDirection !== "ltr" && layoutDirection !== "rtl")) {
            return null;
        }
        const requests = decodeItems(value.requests, decodePendingRequest);
        const completedResponses = decodeItems(value.completedResponses, decodeCompletedResponse);
        return requests && completedResponses
            ? definedFields({layoutDirection, strings, requests, completedResponses}) : null;
    }

    function decodeDisplayAccount(value) {
        if (!isRecord(value)) { return null; }
        const {name, croppedAddress, icon} = value;
        if (typeof name !== "string" || typeof croppedAddress !== "string") { return null; }
        return definedFields({name, croppedAddress, icon: typeof icon === "string" ? icon : undefined});
    }

    function decodeSelectableAccount(value) {
        const display = decodeDisplayAccount(value);
        if (!display) { return null; }
        const {walletId, coin, address, derivationPath, isSelected} = value;
        if (typeof walletId !== "string" || !SELECTION_ACCOUNT_COINS.has(coin) ||
            typeof address !== "string" || typeof derivationPath !== "string" ||
            derivationPath.length === 0 || typeof isSelected !== "boolean") {
            return null;
        }
        return {...display, walletId, coin, address, derivationPath, isSelected};
    }

    function decodeNetwork(value) {
        if (!isRecord(value)) { return null; }
        const {chainId, name, isSelected, isCustom} = value;
        if (!isCanonicalEthereumChainId(chainId) || typeof name !== "string" ||
            typeof isSelected !== "boolean" || !isOptionalBoolean(isCustom)) {
            return null;
        }
        return definedFields({chainId, name, isSelected, isCustom});
    }

    function decodeSelection(review) {
        const {canSelectNetwork, allowsEmptySelection, emptyMessage} = review;
        if (typeof canSelectNetwork !== "boolean" || typeof allowsEmptySelection !== "boolean" ||
            !isOptionalString(emptyMessage)) {
            return null;
        }
        const accounts = decodeItems(review.accounts, decodeSelectableAccount);
        if (!accounts || !hasUniqueValues(accounts, accountIdentityKey) ||
            !hasUniqueValues(accounts.filter(account => account.isSelected), account => account.coin) ||
            (!canSelectNetwork && accounts.some(account => account.coin === "ethereum"))) {
            return null;
        }
        const networks = review.networks === undefined
            ? undefined : decodeItems(review.networks, decodeNetwork);
        if (networks === null || (canSelectNetwork && networks === undefined) ||
            (networks && (!hasUniqueValues(networks, network => network.chainId) ||
                networks.filter(network => network.isSelected).length > 1))) {
            return null;
        }
        return definedFields({canSelectNetwork, allowsEmptySelection, emptyMessage, accounts, networks});
    }

    function decodeCluster(value) {
        if (!isRecord(value)) { return null; }
        const {value: cluster, label, isSelected} = value;
        return SOLANA_CLUSTER_VALUES.has(cluster) && typeof label === "string" &&
            typeof isSelected === "boolean" ? {value: cluster, label, isSelected} : null;
    }

    function decodeMessage(review) {
        const account = decodeDisplayAccount(review.account);
        const {meta, requiresClusterSelection} = review;
        if (!account || typeof meta !== "string") { return null; }
        if (review.clusters === undefined) {
            return requiresClusterSelection === undefined ? {account, meta} : null;
        }
        const clusters = decodeItems(review.clusters, decodeCluster);
        if (typeof requiresClusterSelection !== "boolean" || !clusters || clusters.length === 0 ||
            !hasUniqueValues(clusters, cluster => cluster.value)) {
            return null;
        }
        const selectedCount = clusters.filter(cluster => cluster.isSelected).length;
        return selectedCount === (requiresClusterSelection ? 0 : 1)
            ? {account, meta, clusters, requiresClusterSelection} : null;
    }

    function decodeEditor(value) {
        if (!isRecord(value)) { return null; }
        const {usesEIP1559, nonce, gasPriceGwei, maxPriorityFeePerGasGwei, maxFeePerGasGwei,
            suggestedGasPriceGwei, suggestedMaxPriorityFeePerGasGwei, suggestedMaxFeePerGasGwei} = value;
        if (typeof usesEIP1559 !== "boolean" || typeof nonce !== "string" ||
            ![gasPriceGwei, maxPriorityFeePerGasGwei, maxFeePerGasGwei,
                suggestedGasPriceGwei, suggestedMaxPriorityFeePerGasGwei, suggestedMaxFeePerGasGwei]
                .every(isOptionalString) ||
            (usesEIP1559
                ? typeof maxPriorityFeePerGasGwei !== "string" || typeof maxFeePerGasGwei !== "string"
                : typeof gasPriceGwei !== "string")) {
            return null;
        }
        return definedFields({usesEIP1559, nonce, gasPriceGwei, maxPriorityFeePerGasGwei, maxFeePerGasGwei,
            suggestedGasPriceGwei, suggestedMaxPriorityFeePerGasGwei, suggestedMaxFeePerGasGwei});
    }

    function decodeSlider(value) {
        if (!isRecord(value)) { return null; }
        const {visible, position, maximum} = value;
        return typeof visible === "boolean" && Number.isFinite(position) && Number.isFinite(maximum)
            ? {visible, position, maximum} : null;
    }

    function decodeAlertAction(value) {
        if (!isRecord(value)) { return null; }
        const {title, action} = value;
        return typeof title === "string" && ALERT_ACTIONS.has(action) ? {title, action} : null;
    }

    function decodeAlert(value) {
        if (!isRecord(value)) { return null; }
        const {title, message} = value;
        if (typeof title !== "string" || typeof message !== "string") { return null; }
        const actions = decodeItems(value.actions, decodeAlertAction);
        return actions && actions.length > 0 ? {title, message, actions} : null;
    }

    function decodeTransaction(review) {
        const {networkName, phase, balance, valueLine, dataInterpretation, editorRequestToken, feeLines} = review;
        if (typeof networkName !== "string" || !TRANSACTION_PHASES.has(phase) ||
            ![balance, valueLine, dataInterpretation].every(isOptionalString) ||
            (editorRequestToken !== undefined && !Number.isSafeInteger(editorRequestToken)) ||
            !Array.isArray(feeLines) || !feeLines.every(line => typeof line === "string")) {
            return null;
        }
        const account = decodeDisplayAccount(review.account);
        const slider = decodeSlider(review.slider);
        const editor = decodeEditor(review.editor);
        const alert = review.alert === undefined ? undefined : decodeAlert(review.alert);
        if (!account || !slider || !editor || alert === null) { return null; }
        return definedFields({account, networkName, phase, balance, valueLine, dataInterpretation,
            editorRequestToken, feeLines: feeLines.slice(), slider, editor, alert});
    }

    function decodeReview(review, actions) {
        if (!isRecord(review)) { return null; }
        const {kind, reviewToken, title, primaryTitle} = review;
        if (!isRequestToken(reviewToken) || typeof title !== "string" ||
            !isOptionalString(primaryTitle) || actions.includes("retry") ||
            (kind !== "sendTransaction" && (review.alert !== undefined ||
                actions.some(action => action !== "approve" && action !== "reject")))) {
            return null;
        }
        let content;
        switch (kind) {
            case "selectAccount":
            case "switchAccount":
                content = decodeSelection(review);
                break;
            case "signMessage":
                content = decodeMessage(review);
                break;
            case "sendTransaction":
                content = decodeTransaction(review);
                break;
            case "addChain":
                content = typeof review.chainName === "string" && typeof review.rpcURL === "string"
                    ? {chainName: review.chainName, rpcURL: review.rpcURL} : null;
                break;
            default:
                return null;
        }
        return content && definedFields({kind, reviewToken, title, primaryTitle, ...content});
    }

    function decodeApprovalState(value, expectedRequestID) {
        if (!isRecord(value)) { return null; }
        const {id, state, host, error, editsError, actions} = value;
        if (!isValidRequestId(id) || id !== expectedRequestID || !APPROVAL_STATES.has(state) ||
            (host !== undefined && (typeof host !== "string" || host.length === 0)) ||
            !isOptionalString(error) || !isOptionalBoolean(editsError) ||
            !Array.isArray(actions) || !actions.every(action => APPROVAL_ACTIONS.has(action)) ||
            !hasUniqueValues(actions, action => action)) {
            return null;
        }
        const decoded = definedFields({id, state, host, error, editsError, actions: actions.slice()});
        if (state !== "review") {
            if (value.review !== undefined || (state === "error"
                ? typeof error !== "string" || actions.length === 0 ||
                    actions.some(action => action !== "retry" && action !== "reject")
                : actions.length !== 0)) {
                return null;
            }
            return decoded;
        }
        if (typeof host !== "string") { return null; }
        const review = decodeReview(value.review, actions);
        return review ? {...decoded, review} : null;
    }

    function decodeCommandResult(raw, expectedRequestID) {
        if (!hasExactKeys(raw, ["status", "approval"]) ||
            !["ok", "ignored", "unavailable"].includes(raw.status)) {
            return null;
        }
        if (raw.approval === null) {
            return raw.status === "ok" ? null : {status: raw.status, approval: null};
        }
        if (raw.status === "unavailable") { return null; }
        const approval = decodeApprovalState(raw.approval, expectedRequestID);
        return approval ? {status: raw.status, approval} : null;
    }

    return Object.freeze({
        accountIdentityKey,
        decodeApprovalState,
        decodeCommandResult,
        decodeQueue,
    });
});
