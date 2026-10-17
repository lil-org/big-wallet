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
        PROVIDER_REPLACED_ERROR_CODE, PROVIDER_REPLACED_MESSAGE, NATIVE_CONTEXT_KEY,
        MAX_RESPONSE_READY_IDS, MANUAL_SWITCH_INTENT_SUBJECT,
        MANUAL_SWITCH_ACKNOWLEDGED_SUBJECT, MAX_MANUAL_SWITCH_JSON_LENGTH,
        WORKFLOW_POLICY, RPC_POLICY, RUNTIME_MESSAGE_SUBJECTS,
    } = protocol.constants;
    const hasOwn = (value, key) => Object.prototype.hasOwnProperty.call(value, key);
    const ownDescriptor = Object.getOwnPropertyDescriptor;
    const isSafeInteger = Number.isSafeInteger;
    const freeze = Object.freeze;
    const apply = Reflect.apply;
    const charCodeAt = String.prototype.charCodeAt;
    const decodeMessage = protocol.decode;
    const isMessage = protocol.isValid;

    function pageValue(value, key) {
        const descriptor = ownDescriptor(value, key);
        if (!descriptor || !("value" in descriptor)) {
            throw new Error("Invalid page response");
        }
        return descriptor.value;
    }

    function optionalPageValue(value, key) {
        return ownDescriptor(value, key) ? pageValue(value, key) : undefined;
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

    function rpcRequestByteCount(body) {
        const maximum = RPC_POLICY.maximumRequestBytes;
        if (typeof body !== "string" || body.length > maximum) { return null; }
        let bytes = 0;
        for (let index = 0; index < body.length; index += 1) {
            const code = apply(charCodeAt, body, [index]);
            if (code < 0x80) { bytes += 1; }
            else if (code < 0x800) { bytes += 2; }
            else if (code >= 0xd800 && code <= 0xdbff && index + 1 < body.length &&
                apply(charCodeAt, body, [index + 1]) >= 0xdc00 && apply(charCodeAt, body, [index + 1]) <= 0xdfff) {
                bytes += 4;
                index += 1;
            } else { bytes += 3; }
            if (bytes > maximum) { return null; }
        }
        return bytes;
    }

    function rpcAdmissionError(reason) {
        return {
            code: -32005,
            message: reason === "request_too_large" ? "RPC request is too large" : "Too many pending RPC requests",
            data: {reason, dispatched: false},
        };
    }

    function createRPCRequestBudget(maximumOutstanding = RPC_POLICY.maximumOutstandingRequests) {
        const origins = new Map;
        let outstanding = 0;
        let retainedBytes = 0;
        return freeze({
            reserve(origin, bytes) {
                const originCount = origins.get(origin) ?? 0;
                if (outstanding >= maximumOutstanding || originCount >= RPC_POLICY.maximumOutstandingPerOrigin ||
                    retainedBytes + bytes > RPC_POLICY.maximumRetainedRequestBytes) { return null; }
                outstanding += 1;
                retainedBytes += bytes;
                origins.set(origin, originCount + 1);
                let released = false;
                return () => {
                    if (released) { return; }
                    released = true;
                    outstanding -= 1;
                    retainedBytes -= bytes;
                    const remaining = origins.get(origin) - 1;
                    if (remaining === 0) { origins.delete(origin); }
                    else { origins.set(origin, remaining); }
                };
            },
        });
    }

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

    function privacyForTab(tab, privateContext) {
        if (privateContext === true || tab?.incognito === true) { return "private"; }
        if (privateContext !== undefined && typeof privateContext !== "boolean") { return "unknown"; }
        return typeof tab?.incognito === "boolean" ? "normal" : "unknown";
    }

    function makeNativeContext(source, privateBrowsing, metadata = {}) {
        if (typeof privateBrowsing !== "boolean") { return null; }
        const context = decodeMessage("NativeTransportContext", {source, privateBrowsing, ...metadata});
        if (!context || source === "site" && (
            configurationIdentityForURL(context.site.configurationKey)?.configurationKey !== context.site.configurationKey ||
            configurationIdentityForURL(context.site.configurationKey)?.host !== context.site.host
        )) { return null; }
        return context;
    }

    function popupNativeContext(tab, privateContext) {
        const privacy = privacyForTab(tab, privateContext);
        return makeNativeContext("popup", privacy === "unknown" ? undefined : privacy === "private");
    }

    function workerNativeContext(privateBrowsing) {
        return makeNativeContext("worker", privateBrowsing);
    }

    function runtimeNativeContext(context, request) {
        if (context?.kind === "content") {
            return makeNativeContext("site", context.privacy === "unknown" ? undefined : context.privacy === "private", {
                site: context.identity,
                document: context.document,
            });
        }
        if (context?.kind === "popup") {
            const asserted = decodeMessage("NativePopupContext", request?.[NATIVE_CONTEXT_KEY]);
            if (!asserted) { return null; }
            return context.privacy === "private" ? makeNativeContext("popup", true) : asserted;
        }
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
            const tab = optionalPageValue(sender, "tab");
            const privateContext = optionalPageValue(sender, "incognito");
            if (privateContext !== undefined && typeof privateContext !== "boolean") { return null; }
            let kind;
            let identity = null;
            let tabId = null;
            let document = null;
            let privacy = privateContext === true ? "private" : "unknown";
            if (tab !== undefined) {
                if (!hasOwn(sender, "tab") || !isRecord(tab)) { return null; }
                tabId = pageValue(tab, "id");
                if (!isSafeInteger(tabId) || tabId < 0 || pageValue(sender, "frameId") !== 0) {
                    return null;
                }
                identity = configurationIdentityForURL(url);
                if (!identity) { return null; }
                const origin = optionalPageValue(sender, "origin");
                if (!identity.configurationKey.startsWith("file:") && origin !== undefined && origin !== identity.configurationKey) {
                    return null;
                }
                const documentId = optionalPageValue(sender, "documentId");
                if (documentId !== undefined && (typeof documentId !== "string" ||
                    documentId.length === 0 || documentId.length > 128)) { return null; }
                document = freeze({tabId, frameId: 0, ...(documentId === undefined ? {} : {documentId})});
                privacy = privacyForTab({incognito: optionalPageValue(tab, "incognito")}, privateContext);
                kind = "content";
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
                document,
                privacy,
                tabId,
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
        return function sendTrustedNativeMessage(message, context) {
            const supplied = decodeMessage("NativeTransportContext", context);
            const trusted = supplied && makeNativeContext(supplied.source, supplied.privateBrowsing,
                supplied.source === "site" ? {site: supplied.site, document: supplied.document} : {});
            if (!trusted) { throw new TypeError("Native request context is unavailable"); }
            const payload = {...message};
            if (hasOwn(payload, NATIVE_CONTEXT_KEY)) { throw new TypeError("Native request context must be supplied separately"); }
            const type = Object.prototype.hasOwnProperty.call(payload, "subject") ? "NativeCommand" : "DappRequest";
            if (trusted.source === "site") {
                for (const name of ["host", "configurationKey"]) {
                    if (hasOwn(payload, name) && payload[name] !== trusted.site[name]) {
                        throw new TypeError("Native request identity changed");
                    }
                }
                if (type === "DappRequest") { payload.host = trusted.site.host; }
                if (type === "DappRequest" || ["getLatestConfiguration", "disconnect", "pollResponse", "acknowledgeResponse", "showApproval"].includes(payload.subject)) {
                    payload.configurationKey = trusted.site.configurationKey;
                }
            }
            const checked = protocol.build(type, payload);
            return sendRawNativeMessage({
                ...checked,
                [NATIVE_CONTEXT_KEY]: trusted,
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
        NATIVE_CONTEXT_KEY,
        PROVIDER_REPLACED_ERROR_CODE,
        PROVIDER_REPLACED_MESSAGE,
        WORKFLOW_POLICY,
        RPC_POLICY,
        WORKFLOW_VERSION,
        authorizeRuntimeMessage,
        configurationIdentityForURL,
        decodeMessage,
        isMessage,
        decodeConfigurationSnapshot,
        decodePageResponse,
        decodeNativeResponse,
        createTrustedNativeMessageSender,
        popupNativeContext,
        privacyForTab,
        runtimeNativeContext,
        rpcRequestByteCount,
        rpcAdmissionError,
        createRPCRequestBudget,
        workerNativeContext,
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
        isValidRequestId,
        responseReadyIds,
        withTimeout,
    });
});
