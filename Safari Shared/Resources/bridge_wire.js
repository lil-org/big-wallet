// ∅ 2026 lil org

(function (root, factory) {
    const wire = factory();
    if (typeof module === "object" && module.exports) {
        module.exports = wire;
    } else {
        root.BigWalletBridgeWire = wire;
    }
})(typeof globalThis !== "undefined" ? globalThis : this, function () {
    const WORKFLOW_VERSION = 3;
    const PAGE_BRIDGE_PROTOCOL_VERSION = 1;
    const PAGE_TO_CONTENT_DIRECTION = "big-wallet-provider-v1";
    const CONTENT_TO_PAGE_DIRECTION = "big-wallet-content-v1";
    const PROVIDER_REPLACED_ERROR_CODE = 4900;
    const PROVIDER_REPLACED_MESSAGE = "Big Wallet provider was replaced";
    const ETHEREUM_AUTHORIZATION_FAILURE_KEY =
        "__bwEthereumAuthorizationFailure";
    const ETHEREUM_AUTHORIZATION_FAILURE_VERSION = "v1";
    const APPROVAL_COMMITTED_KEY = "__bwApprovalCommitted";
    const NATIVE_STALE_RESPONSE_KEY = "__bwStale";
    const PRIVATE_BROWSING_KEY = "__bwPrivateBrowsing";
    const MAX_RESPONSE_READY_IDS = 16;
    const MINUTE = 60 * 1000;
    const WORKFLOW_POLICY = Object.freeze({
        maximumNativeChainIdHex: "7fffffffffffffff",
        maximumRequests: 8,
        maximumRequestsPerHost: 4,
        maximumRetainedRequests: 16,
        requestTTLMilliseconds: 15 * MINUTE,
        responseExpiryMilliseconds: 60 * MINUTE,
        selectionAccountCoins: Object.freeze(["ethereum", "solana"]),
        solanaClusterValues: Object.freeze(["mainnetBeta", "devnet", "testnet"]),
    });
    const PRIVATE_TOKEN_PATTERN = /^[0-9a-f]{32}$/;
    const REQUEST_TOKEN_PATTERN =
        /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
    const BASE58_ALPHABET =
        "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";
    const hasOwn = (value, key) =>
        Object.prototype.hasOwnProperty.call(value, key);

    function isRecord(value) {
        return value !== null && typeof value === "object" && !Array.isArray(value);
    }

    function hasExactKeys(value, expectedKeys) {
        if (!isRecord(value)) { return false; }
        const keys = Object.keys(value);
        return keys.length === expectedKeys.length &&
            expectedKeys.every(key => hasOwn(value, key));
    }

    function isValidRequestId(value) {
        return Number.isSafeInteger(value);
    }

    function isPrivateToken(value) {
        return typeof value === "string" && PRIVATE_TOKEN_PATTERN.test(value);
    }

    function isRequestToken(value) {
        return typeof value === "string" && REQUEST_TOKEN_PATTERN.test(value);
    }

    function isNativeEnqueueAcknowledgement(response, id) {
        return hasExactKeys(response, [
                "approvalRequired", "id", "requestToken", "revisions",
            ]) &&
            response.id === id &&
            typeof response.approvalRequired === "boolean" &&
            isRequestToken(response.requestToken) &&
            isProviderRevisions(response.revisions);
    }

    function isCorrelatedDappResponse(response, id) {
        return isRecord(response) && response.id === id &&
            typeof response.name === "string" &&
            !hasOwn(response, "requestToken") &&
            !hasOwn(response, "approvalRequired");
    }

    function isCorrelatedRPCResponse(response, id) {
        return isRecord(response) && response.id === id &&
            (hasOwn(response, "result") || hasOwn(response, "error"));
    }

    function isCanonicalEthereumChainId(value) {
        if (typeof value !== "string" || !/^0x[1-9a-f][0-9a-f]*$/.test(value)) {
            return false;
        }
        const digits = value.slice(2);
        const maximum = WORKFLOW_POLICY.maximumNativeChainIdHex;
        return digits.length < maximum.length ||
            digits.length === maximum.length && digits <= maximum;
    }

    function isSolanaPublicKey(value) {
        if (typeof value !== "string" || value.length < 32 || value.length > 44) {
            return false;
        }
        const bytes = [0];
        for (let index = 0; index < value.length; index += 1) {
            const digit = BASE58_ALPHABET.indexOf(value[index]);
            if (digit < 0) { return false; }
            let carry = digit;
            for (let byte = 0; byte < bytes.length; byte += 1) {
                carry += bytes[byte] * 58;
                bytes[byte] = carry & 0xff;
                carry >>= 8;
            }
            while (carry > 0) {
                bytes.push(carry & 0xff);
                carry >>= 8;
            }
        }
        let leadingZeros = 0;
        while (leadingZeros < value.length && value[leadingZeros] === "1") {
            leadingZeros += 1;
        }
        const significantBytes = bytes.length === 1 && bytes[0] === 0
            ? 0
            : bytes.length;
        return leadingZeros + significantBytes === 32;
    }

    function isConfiguration(value) {
        if (!isRecord(value)) { return false; }
        if (value.provider === "ethereum") {
            return isCanonicalEthereumChainId(value.chainId) &&
                Array.isArray(value.results) &&
                value.results.every(result => typeof result === "string");
        }
        return value.provider === "solana" &&
            isSolanaPublicKey(value.publicKey);
    }

    function parseLatestConfigurations(value) {
        let values;
        if (typeof value === "undefined") {
            values = [];
        } else if (Array.isArray(value)) {
            values = value;
        } else if (isRecord(value) && Array.isArray(value.latestConfigurations)) {
            values = value.latestConfigurations;
        } else if (isConfiguration(value)) {
            values = [value];
        } else {
            return {valid: false, latestConfigurations: []};
        }
        if (values.length > 2 || !values.every(isConfiguration) ||
            new Set(values.map(item => item.provider)).size !== values.length) {
            return {valid: false, latestConfigurations: []};
        }
        return {
            valid: true,
            latestConfigurations: values.map(item => ({...item})),
        };
    }

    function hasLatestConfigurationsWrapper(value) {
        return isRecord(value) && Array.isArray(value.latestConfigurations);
    }

    function isConfigurationKey(value) {
        return typeof value === "string" && value.length > 0;
    }

    function configurationIdentityForURL(value) {
        if (typeof value !== "string") { return null; }
        try {
            const url = new URL(value);
            if ((url.protocol === "http:" || url.protocol === "https:") && url.host) {
                return {
                    host: url.host,
                    configurationKey: url.origin,
                    legacyConfigurationKey: url.host,
                };
            }
            if (url.protocol === "file:") {
                url.search = "";
                url.hash = "";
                return {
                    host: url.href,
                    configurationKey: url.href,
                    legacyConfigurationKey: null,
                };
            }
        } catch {}
        return null;
    }

    function isProviderRevisions(value) {
        return hasExactKeys(value, ["ethereum", "solana"]) &&
            Number.isSafeInteger(value.ethereum) && value.ethereum >= 0 &&
            Number.isSafeInteger(value.solana) && value.solana >= 0;
    }

    function isValidDisconnectRequest(request) {
        if (!isRecord(request) ||
            (request.provider !== "ethereum" && request.provider !== "solana")) {
            return false;
        }
        return request.provider === "solana" &&
            typeof request.id === "undefined" || isValidRequestId(request.id);
    }

    function responseReadyIds(request) {
        if (!isRecord(request) || request.subject !== "responseReady" ||
            request.workflowVersion !== WORKFLOW_VERSION) {
            return null;
        }
        const hasId = hasOwn(request, "id");
        const hasIds = hasOwn(request, "ids");
        if (hasId === hasIds) { return null; }
        if (!hasExactKeys(request, hasIds
            ? ["ids", "subject", "workflowVersion"]
            : ["id", "subject", "workflowVersion"])) {
            return null;
        }
        const ids = hasIds ? request.ids : [request.id];
        return Array.isArray(ids) && ids.length > 0 &&
            ids.length <= MAX_RESPONSE_READY_IDS && ids.every(isValidRequestId)
            ? [...new Set(ids)]
            : null;
    }

    function isPendingRequestAvailable(request) {
        return hasExactKeys(request, ["subject", "workflowVersion"]) &&
            request.subject === "pendingRequestAvailable" &&
            request.workflowVersion === WORKFLOW_VERSION;
    }

    function isConfigurationChanged(request) {
        return hasExactKeys(request, [
                "configurationKey", "latestConfigurations", "revisions",
                "subject", "workflowVersion",
            ]) &&
            request.subject === "configurationChanged" &&
            request.workflowVersion === WORKFLOW_VERSION &&
            isConfigurationKey(request.configurationKey) &&
            Array.isArray(request.latestConfigurations) &&
            parseLatestConfigurations(request.latestConfigurations).valid &&
            isProviderRevisions(request.revisions);
    }

    function genId() {
        return Date.now() + Math.floor(Math.random() * 1000);
    }

    function genPrivateToken() {
        const values = new Uint32Array(4);
        crypto.getRandomValues(values);
        return Array.from(values, value => value.toString(16).padStart(8, "0")).join("");
    }

    function rpcFailureResponse(id) {
        return {id, error: "Failed to communicate with Big Wallet", errorCode: -32603};
    }

    function withTimeout(value, milliseconds) {
        return new Promise((resolve, reject) => {
            let settled = false;
            const finish = (action, result) => {
                if (settled) { return; }
                settled = true;
                clearTimeout(timer);
                action(result);
            };
            const timer = setTimeout(() => {
                const error = new Error("Operation timed out");
                error.name = "TimeoutError";
                finish(reject, error);
            }, milliseconds);
            Promise.resolve(value).then(
                result => finish(resolve, result),
                error => finish(reject, error)
            );
        });
    }

    function createTrustedNativeMessageSender({sendRawNativeMessage}) {
        return function sendTrustedNativeMessage(message, privateBrowsing) {
            const payload = {...message};
            delete payload[PRIVATE_BROWSING_KEY];
            return sendRawNativeMessage({
                ...payload,
                [PRIVATE_BROWSING_KEY]: privateBrowsing === true,
            });
        };
    }

    return Object.freeze({
        CONTENT_TO_PAGE_DIRECTION,
        APPROVAL_COMMITTED_KEY,
        ETHEREUM_AUTHORIZATION_FAILURE_KEY,
        ETHEREUM_AUTHORIZATION_FAILURE_VERSION,
        MAX_RESPONSE_READY_IDS,
        NATIVE_STALE_RESPONSE_KEY,
        PAGE_BRIDGE_PROTOCOL_VERSION,
        PAGE_TO_CONTENT_DIRECTION,
        PRIVATE_BROWSING_KEY,
        PROVIDER_REPLACED_ERROR_CODE,
        PROVIDER_REPLACED_MESSAGE,
        WORKFLOW_POLICY,
        WORKFLOW_VERSION,
        configurationIdentityForURL,
        createTrustedNativeMessageSender,
        genId,
        genPrivateToken,
        hasExactKeys,
        hasLatestConfigurationsWrapper,
        isConfigurationChanged,
        isConfiguration,
        isCanonicalEthereumChainId,
        isConfigurationKey,
        isCorrelatedDappResponse,
        isCorrelatedRPCResponse,
        isLowercaseUUID: isRequestToken,
        isNativeEnqueueAcknowledgement,
        isPendingRequestAvailable,
        isPrivateToken,
        isProviderRevisions,
        isRecord,
        isRequestToken,
        isValidDisconnectRequest,
        isValidRequestId,
        parseLatestConfigurations,
        responseReadyIds,
        rpcFailureResponse,
        withTimeout,
    });
});
