// ∅ 2026 lil org

(function (root, factory) {
    if (typeof module === "object" && module.exports) {
        module.exports = factory(require("./bridge_wire.js"));
    } else {
        root.BigWalletPopupWire = factory(root.BigWalletBridgeWire);
    }
})(typeof globalThis !== "undefined" ? globalThis : this, function (wire) {
    "use strict";

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

    function decodeQueue(value) {
        return wire.decodeMessage("PopupQueue", value);
    }

    function validSelection(review) {
        return hasUniqueValues(review.accounts, accountIdentityKey) &&
            hasUniqueValues(review.accounts.filter(account => account.isSelected), account => account.coin) &&
            (review.canSelectNetwork || !review.accounts.some(account => account.coin === "ethereum")) &&
            (!review.canSelectNetwork || review.networks !== undefined) &&
            (!review.networks || hasUniqueValues(review.networks, network => network.chainId) &&
                review.networks.filter(network => network.isSelected).length <= 1);
    }

    function validMessage(review) {
        if (review.clusters === undefined) { return review.requiresClusterSelection === undefined; }
        return typeof review.requiresClusterSelection === "boolean" && review.clusters.length > 0 &&
            hasUniqueValues(review.clusters, cluster => cluster.value) &&
            review.clusters.filter(cluster => cluster.isSelected).length === (review.requiresClusterSelection ? 0 : 1);
    }

    function validReview(review, actions) {
        if (actions.includes("retry") || review.kind !== "sendTransaction" &&
            actions.some(action => action !== "approve" && action !== "reject")) { return false; }
        switch (review.kind) {
        case "accountSelection": return validSelection(review);
        case "signMessage": return validMessage(review);
        case "sendTransaction":
            return review.editor.usesEIP1559
                ? typeof review.editor.maxPriorityFeePerGasGwei === "string" && typeof review.editor.maxFeePerGasGwei === "string"
                : typeof review.editor.gasPriceGwei === "string";
        case "addChain": return true;
        default: return false;
        }
    }

    function decodeApprovalState(value, expectedRequestID) {
        const decoded = wire.decodeMessage("PopupApprovalState", value);
        if (!decoded || decoded.id !== expectedRequestID ||
            !hasUniqueValues(decoded.actions, action => action)) { return null; }
        if (decoded.state === "review") {
            return validReview(decoded.review, decoded.actions) ? decoded : null;
        }
        return (decoded.state === "error"
            ? decoded.actions.length > 0 && decoded.actions.every(action => action === "retry" || action === "reject")
            : decoded.actions.length === 0) ? decoded : null;
    }

    function decodeCommandResult(value, expectedRequestID) {
        const decoded = wire.decodeMessage("PopupCommandResult", value);
        if (!decoded) { return null; }
        if (decoded.approval === null) { return decoded.status === "ok" ? null : decoded; }
        if (decoded.status === "unavailable") { return null; }
        return decodeApprovalState(decoded.approval, expectedRequestID) ? decoded : null;
    }

    return Object.freeze({
        accountIdentityKey,
        decodeApprovalState,
        decodeCommandResult,
        decodeQueue,
    });
});
