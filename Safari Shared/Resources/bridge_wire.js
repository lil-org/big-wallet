// ∅ 2026 lil org

(function (root, factory) {
    const wire = factory(typeof module === "object" && module.exports
        ? require("./protocol.generated.js") : root.BigWalletProtocol);
    if (typeof module === "object" && module.exports) {
        module.exports = wire;
    } else {
        root.BigWalletBridgeWire = wire;
    }
})(typeof globalThis !== "undefined" ? globalThis : this, function (protocol) {
    const BUILD_VERSION = "1.0.99+148";
    const {
        WORKFLOW_VERSION, PAGE_TO_CONTENT_DIRECTION, CONTENT_TO_PAGE_DIRECTION,
        PROVIDER_REPLACED_ERROR_CODE, PROVIDER_REPLACED_MESSAGE, PRIVATE_BROWSING_KEY,
        MAX_RESPONSE_READY_IDS, MANUAL_SWITCH_INTENT_SUBJECT,
        MANUAL_SWITCH_ACKNOWLEDGED_SUBJECT, MAX_MANUAL_SWITCH_JSON_LENGTH,
        WORKFLOW_POLICY, RUNTIME_MESSAGE_SUBJECTS,
    } = protocol.constants;
    const hasOwn = (value, key) => Object.prototype.hasOwnProperty.call(value, key);
    const ownDescriptor = Object.getOwnPropertyDescriptor;
    const isSafeInteger = Number.isSafeInteger;
    const freeze = Object.freeze;
    const decodeMessage = protocol.decode;
    const isMessage = protocol.isValid;

    function pageValue(value, key) {
        const descriptor = ownDescriptor(value, key);
        if (!descriptor || !("value" in descriptor)) {
            throw new Error("Invalid page response");
        }
        return descriptor.value;
    }

    function decodeConfigurationSnapshot(value) {
        return decodeMessage("ConfigurationSnapshot", value);
    }

    function decodePageResponse(value, correlationId) {
        const decoded = decodeMessage("PageResponse", value);
        if (!decoded) { return null; }
        return (decoded.kind === "result" || decoded.kind === "error") &&
            typeof correlationId !== "undefined" && decoded.id !== correlationId
            ? null : decoded;
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

    function isValidRequestId(value) { return isMessage("RequestID", value); }
    function isPrivateToken(value) { return isMessage("PrivateToken", value); }
    function isRequestToken(value) { return isMessage("RequestToken", value); }

    function hasBoundedJSON(value) {
        try {
            const json = JSON.stringify(value);
            return typeof json === "string" &&
                json.length <= MAX_MANUAL_SWITCH_JSON_LENGTH;
        } catch {
            return false;
        }
    }

    function isAuthorityVersion(value) { return isMessage("AuthorityVersion", value); }

    function isNativeEnqueueAcknowledgement(response, id) {
        const decoded = decodeMessage("NativeAdmission", response);
        return decoded !== null && decoded.id === id;
    }

    function decodeNativeResponse(value, correlationId) {
        const decoded = decodeMessage("NativeResponse", value);
        if (!decoded || correlationId !== undefined && decoded.id !== correlationId ||
            decoded.provider === "multiple" && !hasBoundedJSON(decoded)) { return null; }
        return decoded;
    }

    function isCorrelatedRPCResponse(response, id) {
        return isRecord(response) && response.id === id &&
            (hasOwn(response, "result") || hasOwn(response, "error"));
    }

    function isCanonicalEthereumChainId(value) { return isMessage("EthereumChainID", value); }
    function isSolanaPublicKey(value) { return isMessage("SolanaPublicKey", value); }

    function configurationIdentityForURL(value) {
        if (typeof value !== "string") { return null; }
        try {
            const url = new URL(value);
            if ((url.protocol === "http:" || url.protocol === "https:") && url.host) {
                return {
                    host: url.host,
                    configurationKey: url.origin,
                };
            }
            if (url.protocol === "file:") {
                url.search = "";
                url.hash = "";
                return {
                    host: url.href,
                    configurationKey: url.href,
                };
            }
        } catch {}
        return null;
    }

    function authorizeRuntimeMessage(receiver, request, sender, runtime) {
        try {
            if (typeof receiver !== "string" || !isRecord(request) || !isRecord(sender)) {
                return null;
            }
            const extensionId = runtime?.id;
            const subject = pageValue(request, "subject");
            const url = pageValue(sender, "url");
            if (typeof extensionId !== "string" || extensionId.length === 0 ||
                pageValue(sender, "id") !== extensionId || typeof subject !== "string" ||
                typeof url !== "string") {
                return null;
            }
            const tab = sender.tab;
            let kind;
            let identity = null;
            let tabId = null;
            let favicon = null;
            if (tab !== undefined) {
                if (!hasOwn(sender, "tab") || !isRecord(tab)) { return null; }
                tabId = pageValue(tab, "id");
                if (!isSafeInteger(tabId) || tabId < 0 || pageValue(sender, "frameId") !== 0) {
                    return null;
                }
                identity = configurationIdentityForURL(url);
                if (!identity) { return null; }
                kind = "content";
                const faviconURL = tab.favIconUrl;
                favicon = typeof faviconURL === "string" ? faviconURL : null;
                freeze(identity);
            } else if (url === runtime.getURL("popup.html")) {
                kind = "popup";
            } else {
                const rootURL = runtime.getURL("");
                if (url !== runtime.getURL("service_worker.js") &&
                    url !== rootURL && `${url}/` !== rootURL) {
                    return null;
                }
                kind = "worker";
            }
            if (!RUNTIME_MESSAGE_SUBJECTS[receiver]?.[kind]?.includes(subject)) { return null; }
            return freeze({
                kind,
                identity,
                privateBrowsing: tab?.incognito === true || sender.incognito === true,
                tabId,
                favicon,
            });
        } catch {
            return null;
        }
    }

    function isProviderRevisions(value) { return isMessage("ProviderRevisions", value); }

    function isManualSwitchAcknowledgement(value, id, configurationKey) {
        const decoded = decodeMessage("ManualSwitchAcknowledgement", value);
        return decoded !== null && decoded.id === id &&
            decoded.configurationKey === configurationKey &&
            configurationIdentityForURL(configurationKey)?.configurationKey === configurationKey &&
            hasBoundedJSON(decoded);
    }

    function isManualSwitchTerminalResponse(response, id) {
        const terminal = decodeNativeResponse(response, id);
        return terminal !== null && terminal.name === "switchAccount" &&
            terminal.provider === "multiple" && (terminal.kind === "error" ||
                terminal.result === null);
    }

    function isValidDisconnectRequest(request) { return isMessage("PageDisconnect", request); }

    function responseReadyIds(request) {
        const decoded = decodeMessage("ResponseReady", request);
        return decoded ? [...new Set(decoded.ids || [decoded.id])] : null;
    }

    function isPendingRequestAvailable(request) { return isMessage("PendingRequestAvailable", request); }

    function isConfigurationInvalidated(request) {
        const decoded = decodeMessage("ConfigurationInvalidated", request);
        return decoded !== null &&
            configurationIdentityForURL(decoded.configurationKey)?.configurationKey === decoded.configurationKey;
    }

    function genId() {
        return Date.now() + Math.floor(Math.random() * 1000);
    }

    function genPrivateToken() {
        const values = new Uint32Array(4);
        crypto.getRandomValues(values);
        return Array.from(values, value => value.toString(16).padStart(8, "0")).join("");
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
            const type = Object.prototype.hasOwnProperty.call(payload, "subject") ? "NativeCommand" : "DappRequest";
            const checked = protocol.build(type, payload);
            return sendRawNativeMessage({
                ...checked,
                [PRIVATE_BROWSING_KEY]: privateBrowsing === true,
            });
        };
    }

    return Object.freeze({
        BUILD_VERSION,
        CONTENT_TO_PAGE_DIRECTION,
        MAX_RESPONSE_READY_IDS,
        MANUAL_SWITCH_ACKNOWLEDGED_SUBJECT,
        MANUAL_SWITCH_INTENT_SUBJECT,
        PAGE_TO_CONTENT_DIRECTION,
        PRIVATE_BROWSING_KEY,
        PROVIDER_REPLACED_ERROR_CODE,
        PROVIDER_REPLACED_MESSAGE,
        WORKFLOW_POLICY,
        WORKFLOW_VERSION,
        authorizeRuntimeMessage,
        configurationIdentityForURL,
        decodeMessage,
        isMessage,
        decodeConfigurationSnapshot,
        decodePageResponse,
        decodeNativeResponse,
        createTrustedNativeMessageSender,
        genId,
        genPrivateToken,
        hasExactKeys,
        isConfigurationInvalidated,
        isAuthorityVersion,
        isCanonicalEthereumChainId,
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
        responseReadyIds,
        withTimeout,
    });
});
