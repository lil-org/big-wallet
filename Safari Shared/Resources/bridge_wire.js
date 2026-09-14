// ∅ 2026 lil org

(function (root, factory) {
    const wire = factory();
    if (typeof module === "object" && module.exports) {
        module.exports = wire;
    } else {
        root.BigWalletBridgeWire = wire;
    }
})(typeof globalThis !== "undefined" ? globalThis : this, function () {
    const BUILD_VERSION = "1.0.99+148";
    const WORKFLOW_VERSION = 3;
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
    const MANUAL_SWITCH_INTENT_SUBJECT = "manualSwitchIntent";
    const MANUAL_SWITCH_ACKNOWLEDGED_SUBJECT = "manualSwitchAcknowledged";
    const MAX_MANUAL_SWITCH_JSON_LENGTH = 256 * 1024;
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
    const ownDescriptor = Object.getOwnPropertyDescriptor;
    const ownKeys = Object.keys;
    const createObject = Object.create;
    const defineProperty = Object.defineProperty;
    const freeze = Object.freeze;
    const isArray = Array.isArray;
    const isSafeInteger = Number.isSafeInteger;
    const isFiniteNumber = Number.isFinite;
    const stringIndexOf = Function.prototype.call.bind(String.prototype.indexOf);

    function pageValue(value, key) {
        const descriptor = ownDescriptor(value, key);
        if (!descriptor || !("value" in descriptor)) {
            throw new Error("Invalid page response");
        }
        return descriptor.value;
    }

    function pageRecord(value, keys, optional = []) {
        if (!value || typeof value !== "object" || isArray(value)) {
            throw new Error("Invalid page response");
        }
        const names = ownKeys(value);
        if (names.length < keys.length || names.length > keys.length + optional.length) {
            throw new Error("Invalid page response");
        }
        for (let index = 0; index < names.length; index += 1) {
            let allowed = false;
            for (let key = 0; key < keys.length; key += 1) {
                if (names[index] === keys[key]) { allowed = true; }
            }
            for (let key = 0; key < optional.length; key += 1) {
                if (names[index] === optional[key]) { allowed = true; }
            }
            if (!allowed) { throw new Error("Invalid page response"); }
        }
        for (let index = 0; index < keys.length; index += 1) { pageValue(value, keys[index]); }
        return value;
    }

    function pageJSON(value, ancestors = []) {
        if (value === null || typeof value === "string" || typeof value === "boolean" ||
            typeof value === "number" && isFiniteNumber(value)) {
            return value;
        }
        if (!value || typeof value !== "object") { throw new Error("Invalid page JSON"); }
        for (let index = 0; index < ancestors.length; index += 1) {
            if (ancestors[index] === value) { throw new Error("Invalid page JSON"); }
        }
        const path = createObject(null);
        for (let index = 0; index < ancestors.length; index += 1) { path[index] = ancestors[index]; }
        path[ancestors.length] = value;
        path.length = ancestors.length + 1;
        const array = isArray(value);
        const result = array ? [] : createObject(null);
        const keys = array ? null : ownKeys(value);
        const length = array ? pageValue(value, "length") : keys.length;
        for (let index = 0; index < length; index += 1) {
            const key = array ? `${index}` : keys[index];
            defineProperty(result, key, {
                __proto__: null,
                enumerable: true,
                value: pageJSON(pageValue(value, key), path),
            });
        }
        if (array) {
            defineProperty(result, "toJSON", {__proto__: null, value: undefined});
        }
        return freeze(result);
    }

    function pageError(value) {
        pageRecord(value, ["code", "message"], ["data"]);
        const code = pageValue(value, "code");
        const message = pageValue(value, "message");
        if (!isFiniteNumber(code) || typeof message !== "string") {
            throw new Error("Invalid page error");
        }
        const error = {code, message};
        if (ownDescriptor(value, "data")) {
            defineProperty(error, "data", {
                __proto__: null,
                enumerable: true,
                value: pageJSON(pageValue(value, "data")),
            });
        }
        return freeze(error);
    }

    function configurationSnapshot(value) {
        pageRecord(value, ["revisions", "ethereum", "solana"]);
        const rawRevisions = pageRecord(pageValue(value, "revisions"), ["ethereum", "solana"]);
        const revisions = {
            ethereum: pageValue(rawRevisions, "ethereum"),
            solana: pageValue(rawRevisions, "solana"),
        };
        if (!isSafeInteger(revisions.ethereum) || revisions.ethereum < 0 ||
            !isSafeInteger(revisions.solana) || revisions.solana < 0) {
            throw new Error("Invalid page revisions");
        }
        let ethereum = pageValue(value, "ethereum");
        if (ethereum !== null) {
            pageRecord(ethereum, ["address", "chainId", "reauthorizationRevision"]);
            ethereum = {
                address: pageValue(ethereum, "address"),
                chainId: pageValue(ethereum, "chainId"),
                reauthorizationRevision: pageValue(ethereum, "reauthorizationRevision"),
            };
            if (typeof ethereum.address !== "string" ||
                !isCanonicalEthereumChainId(ethereum.chainId) ||
                !isSafeInteger(ethereum.reauthorizationRevision) ||
                ethereum.reauthorizationRevision < 0) {
                throw new Error("Invalid Ethereum page configuration");
            }
            freeze(ethereum);
        }
        let solana = pageValue(value, "solana");
        if (solana !== null) {
            pageRecord(solana, ["publicKey", "isConnected", "reauthorizationRevision"]);
            solana = {
                publicKey: pageValue(solana, "publicKey"),
                isConnected: pageValue(solana, "isConnected"),
                reauthorizationRevision: pageValue(solana, "reauthorizationRevision"),
            };
            if (!isSolanaPublicKey(solana.publicKey) ||
                typeof solana.isConnected !== "boolean" ||
                !isSafeInteger(solana.reauthorizationRevision) ||
                solana.reauthorizationRevision < 0) {
                throw new Error("Invalid Solana page configuration");
            }
            freeze(solana);
        }
        return freeze({revisions: freeze(revisions), ethereum, solana});
    }

    function decodeConfigurationSnapshot(value) {
        try { return configurationSnapshot(value); } catch { return null; }
    }

    function decodePageResponse(value, correlationId) {
        try {
            if (!value || typeof value !== "object") { return null; }
            const kind = pageValue(value, "kind");
            if (kind === "configuration") {
                pageRecord(value, ["kind", "state"]);
                return freeze({kind, state: configurationSnapshot(pageValue(value, "state"))});
            }
            if (kind === "configurationError") {
                pageRecord(value, ["kind", "error"]);
                return freeze({kind, error: pageError(pageValue(value, "error"))});
            }
            if (kind !== "result" && kind !== "error") { return null; }
            pageRecord(value, kind === "result" ? [
                "kind", "id", "provider", "name", "state", "configurationMatch",
                "result", "approvalCommitted",
            ] : [
                "kind", "id", "provider", "name", "state", "configurationMatch",
                "error", "authorizationFailure",
            ]);
            const id = pageValue(value, "id");
            const provider = pageValue(value, "provider");
            const name = pageValue(value, "name");
            const rawState = pageValue(value, "state");
            const configurationMatch = pageValue(value, "configurationMatch");
            if (!isSafeInteger(id) || typeof correlationId !== "undefined" && id !== correlationId ||
                (provider !== "ethereum" && provider !== "solana") ||
                (name !== null && typeof name !== "string") ||
                (rawState === null ? configurationMatch !== null : typeof configurationMatch !== "boolean")) {
                return null;
            }
            const terminal = {
                kind, id, provider, name,
                state: rawState === null ? null : configurationSnapshot(rawState),
                configurationMatch,
            };
            if (kind === "result") {
                const approvalCommitted = pageValue(value, "approvalCommitted");
                if (typeof approvalCommitted !== "boolean") { return null; }
                return freeze({...terminal, result: pageJSON(pageValue(value, "result")), approvalCommitted});
            }
            const authorizationFailure = pageValue(value, "authorizationFailure");
            if (typeof authorizationFailure !== "boolean") { return null; }
            return freeze({...terminal, error: pageError(pageValue(value, "error")), authorizationFailure});
        } catch {
            return null;
        }
    }

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

    function hasBoundedJSON(value) {
        try {
            const json = JSON.stringify(value);
            return typeof json === "string" &&
                json.length <= MAX_MANUAL_SWITCH_JSON_LENGTH;
        } catch {
            return false;
        }
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
            const digit = stringIndexOf(BASE58_ALPHABET, value[index]);
            if (digit < 0) { return false; }
            let carry = digit;
            for (let byte = 0; byte < bytes.length; byte += 1) {
                carry += bytes[byte] * 58;
                bytes[byte] = carry & 0xff;
                carry >>= 8;
            }
            while (carry > 0) {
                bytes[bytes.length] = carry & 0xff;
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

    function isCanonicalManualSwitchConfigurations(value) {
        if (!Array.isArray(value) ||
            !parseLatestConfigurations(value).valid) {
            return false;
        }
        return value.every(configuration => configuration.provider === "ethereum"
            ? hasExactKeys(configuration, ["chainId", "provider", "results"])
            : hasExactKeys(configuration, ["provider", "publicKey"]));
    }

    function sameManualSwitchConfigurations(left, right) {
        return left.length === right.length && left.every(configuration => {
            const match = right.find(candidate =>
                candidate.provider === configuration.provider
            );
            if (!match) { return false; }
            return configuration.provider === "ethereum"
                ? configuration.chainId === match.chainId &&
                    JSON.stringify(configuration.results) ===
                        JSON.stringify(match.results)
                : configuration.publicKey === match.publicKey;
        });
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

    function isManualSwitchAcknowledgement(value, id, configurationKey) {
        const identity = configurationIdentityForURL(value?.configurationKey);
        return hasExactKeys(value, [
                "approvalRequired", "configurationKey", "id", "requestToken",
                "revisions", "subject", "workflowVersion",
            ]) && value.subject === MANUAL_SWITCH_ACKNOWLEDGED_SUBJECT &&
            value.workflowVersion === WORKFLOW_VERSION && value.id === id &&
            isValidRequestId(value.id) &&
            value.configurationKey === configurationKey &&
            identity?.configurationKey === value.configurationKey &&
            typeof value.approvalRequired === "boolean" &&
            isRequestToken(value.requestToken) &&
            isProviderRevisions(value.revisions) && hasBoundedJSON(value);
    }

    function isManualSwitchTerminalResponse(response, id) {
        if (!isRecord(response) || !isValidRequestId(response.id) ||
            response.id !== id ||
            response.name !== "switchAccount" ||
            (response.provider !== "unknown" && response.provider !== "multiple") ||
            hasOwn(response, "requestToken") ||
            hasOwn(response, "approvalRequired") || !hasBoundedJSON(response)) {
            return false;
        }
        const allowed = new Set([
            "bodies", "configurationToStore", "error", "errorCode",
            "errorDataJSON", "errorPublicKey", "errorSignature", "id",
            "latestConfigurations", "name", "provider",
            "providersToDisconnect", "revisions", APPROVAL_COMMITTED_KEY,
            NATIVE_STALE_RESPONSE_KEY,
        ]);
        if (Object.keys(response).some(key => !allowed.has(key))) { return false; }
        if (hasOwn(response, APPROVAL_COMMITTED_KEY) &&
            response[APPROVAL_COMMITTED_KEY] !== true ||
            hasOwn(response, NATIVE_STALE_RESPONSE_KEY) &&
            response[NATIVE_STALE_RESPONSE_KEY] !== true) {
            return false;
        }
        for (const key of [
            "errorDataJSON", "errorPublicKey", "errorSignature",
        ]) {
            if (hasOwn(response, key) && typeof response[key] !== "string") {
                return false;
            }
        }
        if (hasOwn(response, "errorCode") &&
            !Number.isSafeInteger(response.errorCode)) {
            return false;
        }
        const hasLatest = hasOwn(response, "latestConfigurations");
        const hasRevisions = hasOwn(response, "revisions");
        if (hasLatest !== hasRevisions || hasLatest &&
            (!Array.isArray(response.latestConfigurations) ||
                !parseLatestConfigurations(response.latestConfigurations).valid ||
                !isProviderRevisions(response.revisions))) {
            return false;
        }
        if (hasOwn(response, "configurationToStore") &&
            (!Array.isArray(response.configurationToStore) ||
                !isCanonicalManualSwitchConfigurations(
                    response.configurationToStore
                ))) {
            return false;
        }
        const hasBodies = hasOwn(response, "bodies");
        const hasDisconnects = hasOwn(response, "providersToDisconnect");
        if (hasBodies !== hasDisconnects || hasBodies &&
            (!isCanonicalManualSwitchConfigurations(response.bodies) ||
                !Array.isArray(response.providersToDisconnect) ||
                response.providersToDisconnect.length > 2 ||
                new Set(response.providersToDisconnect).size !==
                    response.providersToDisconnect.length ||
                !response.providersToDisconnect.every(provider =>
                    provider === "ethereum" || provider === "solana"))) {
            return false;
        }
        const hasError = hasOwn(response, "error");
        const hasStored = hasOwn(response, "configurationToStore");
        if (hasError) {
            return typeof response.error === "string" &&
                response.error.length > 0 && !hasStored && !hasBodies;
        }
        const rawSuccess = hasStored && hasBodies && !hasLatest &&
            sameManualSwitchConfigurations(
                response.bodies,
                response.configurationToStore
            ) && !response.providersToDisconnect.some(provider =>
                response.bodies.some(configuration =>
                    configuration.provider === provider
                ));
        const appliedSuccess = hasLatest && !hasStored && !hasBodies;
        return response.provider === "multiple" &&
            (rawSuccess || appliedSuccess) &&
            !hasOwn(response, "errorCode") &&
            !hasOwn(response, "errorDataJSON") &&
            !hasOwn(response, "errorPublicKey") &&
            !hasOwn(response, "errorSignature") &&
            !hasOwn(response, NATIVE_STALE_RESPONSE_KEY);
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
                "configurationKey", "state", "subject", "workflowVersion",
            ]) && request.subject === "configurationChanged" &&
            request.workflowVersion === WORKFLOW_VERSION &&
            isConfigurationKey(request.configurationKey) &&
            decodeConfigurationSnapshot(request.state) !== null;
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
        BUILD_VERSION,
        CONTENT_TO_PAGE_DIRECTION,
        APPROVAL_COMMITTED_KEY,
        ETHEREUM_AUTHORIZATION_FAILURE_KEY,
        ETHEREUM_AUTHORIZATION_FAILURE_VERSION,
        MAX_RESPONSE_READY_IDS,
        MANUAL_SWITCH_ACKNOWLEDGED_SUBJECT,
        MANUAL_SWITCH_INTENT_SUBJECT,
        NATIVE_STALE_RESPONSE_KEY,
        PAGE_TO_CONTENT_DIRECTION,
        PRIVATE_BROWSING_KEY,
        PROVIDER_REPLACED_ERROR_CODE,
        PROVIDER_REPLACED_MESSAGE,
        WORKFLOW_POLICY,
        WORKFLOW_VERSION,
        configurationIdentityForURL,
        decodeConfigurationSnapshot,
        decodePageResponse,
        createTrustedNativeMessageSender,
        genId,
        genPrivateToken,
        hasExactKeys,
        isConfigurationChanged,
        isConfiguration,
        isCanonicalEthereumChainId,
        isConfigurationKey,
        isCorrelatedDappResponse,
        isCorrelatedRPCResponse,
        isManualSwitchAcknowledgement,
        isManualSwitchTerminalResponse,
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
