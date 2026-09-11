// ∅ 2026 lil org

"use strict";

import BigWalletEthereum, {
    requestConnectReplay as ethereumRequestConnectReplay,
} from "./ethereum";
import BigWalletSolana from "./solana";
import Base58 from "./base58";
import {
    decodeProviderErrorData,
    providerReplacementError,
} from "./error";
import {normalizedRPCResponse} from "./rpc_response";
import {
    createStableFacadeRecord,
    reusableStableFacadeRecord,
    stableFacadeVersion,
} from "./stable_facades";
import BigWalletBridgeWire from "../Resources/bridge_wire";

const {
    APPROVAL_COMMITTED_KEY,
    CONTENT_TO_PAGE_DIRECTION,
    ETHEREUM_AUTHORIZATION_FAILURE_KEY,
    ETHEREUM_AUTHORIZATION_FAILURE_VERSION,
    PAGE_TO_CONTENT_DIRECTION,
    hasExactKeys,
} = BigWalletBridgeWire;

const applyFunction = Reflect.apply;
const definePropertyNormally = Object.defineProperty;
const freezeObjectNormally = Object.freeze;
const getOwnPropertyDescriptorNormally = Object.getOwnPropertyDescriptor;
const hasOwnPropertyNormally = Object.prototype.hasOwnProperty;
const isFrozenNormally = Object.isFrozen;
const isArrayNormally = Array.isArray;
const isSafeIntegerNormally = Number.isSafeInteger;
const postWindowMessageNormally = window.postMessage;
const addWindowEventListenerNormally = window.addEventListener;
const maximumEnvelopeItems = 64;
const malformedConfigurationDelivery = freezeObjectNormally({});
const stableFacadeAnchorProperty = "bigWalletInpageStableFacadeAnchorV1";
const stableFacadeProperty = "bigWalletInpageStableFacadeRecord";
const contentHandlerProperty = "bigWalletInpageContentBridgeHandler";
const contentSetupProperty = "bigWalletInpageResponseBridgeSetup";
const announceHandlerProperty = "bigWalletInpageEIP6963AnnounceHandler";
const announceSetupProperty = "bigWalletInpageEIP6963RequestSetup";
const bigWalletIcon = "data:image/svg+xml;base64,PHN2ZyB3aWR0aD0iMTAyNCIgaGVpZ2h0PSIxMDI0IiB2aWV3Qm94PSIwIDAgMTAyNCAxMDI0IiBmaWxsPSJub25lIiB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciPgo8cmVjdCB3aWR0aD0iMTAyNCIgaGVpZ2h0PSIxMDI0IiBmaWxsPSJ3aGl0ZSIvPgo8cGF0aCBkPSJNODI3IDUxMkM4MjcgMzM4LjAzMSA2ODUuOTY5IDE5NyA1MTIgMTk3QzMzOC4wMzEgMTk3IDE5NyAzMzguMDMxIDE5NyA1MTJDMTk3IDY4NS45NjkgMzM4LjAzMSA4MjcgNTEyIDgyN0M2ODUuOTY5IDgyNyA4MjcgNjg1Ljk2OSA4MjcgNTEyWiIgZmlsbD0idXJsKCNwYWludDBfbGluZWFyXzFfMTQpIi8+CjxkZWZzPgo8bGluZWFyR3JhZGllbnQgaWQ9InBhaW50MF9saW5lYXJfMV8xNCIgeDE9IjUxMiIgeTE9IjE5NyIgeDI9IjUxMiIgeTI9IjgyNyIgZ3JhZGllbnRVbml0cz0idXNlclNwYWNlT25Vc2UiPgo8c3RvcCBzdG9wLWNvbG9yPSIjNjJDQ0Y5Ii8+CjxzdG9wIG9mZnNldD0iMSIgc3RvcC1jb2xvcj0iIzAwN0FGRiIvPgo8L2xpbmVhckdyYWRpZW50Pgo8L2RlZnM+Cjwvc3ZnPgo=";

function descriptor(object, name) {
    if (!object || (typeof object !== "object" && typeof object !== "function")) {
        return undefined;
    }
    return getOwnPropertyDescriptorNormally(object, name);
}

function ownValue(object, name) {
    const valueDescriptor = descriptor(object, name);
    return valueDescriptor && "value" in valueDescriptor
        ? valueDescriptor.value
        : undefined;
}

function hasOwn(object, name) {
    return applyFunction(hasOwnPropertyNormally, object, [name]);
}

function defineValue(object, name, value) {
    definePropertyNormally(object, name, {
        configurable: true,
        enumerable: true,
        value,
        writable: true,
    });
}

function defineProviderAlias(object, name, value) {
    try {
        defineValue(object, name, value);
    } catch {
        try { definePropertyNormally(object, name, {value}); } catch {}
    }
}

function trustedStableFacadeAnchor() {
    const anchorDescriptor = descriptor(window, stableFacadeAnchorProperty);
    if (!anchorDescriptor || !("value" in anchorDescriptor) ||
        anchorDescriptor.configurable || anchorDescriptor.enumerable ||
        anchorDescriptor.writable) {
        return null;
    }
    const anchor = anchorDescriptor.value;
    if (!anchor || !isFrozenNormally(anchor) ||
        ownValue(anchor, "version") !== stableFacadeVersion) {
        return null;
    }
    return reusableStableFacadeRecord(ownValue(anchor, "record"))
        ? anchor
        : null;
}

function ensureStableFacadeAnchor(record, initialSnapshots) {
    const anchor = trustedStableFacadeAnchor();
    const trusted = ownValue(anchor, "record");
    if (trusted) {
        if (trusted !== record) {
            throw new Error("Stable facade anchor changed");
        }
        return trusted;
    }
    const current = descriptor(window, stableFacadeAnchorProperty);
    if (current && current.configurable !== true) {
        throw new Error("Stable facade anchor is unavailable");
    }
    const value = freezeObjectNormally({
        initialSnapshots,
        record,
        version: stableFacadeVersion,
    });
    definePropertyNormally(window, stableFacadeAnchorProperty, {
        configurable: false,
        enumerable: false,
        value,
        writable: false,
    });
    return record;
}

function boundedArrayLength(value) {
    if (!isArrayNormally(value)) { return null; }
    const length = ownValue(value, "length");
    return isSafeIntegerNormally(length) && length >= 0 &&
        length <= maximumEnvelopeItems
        ? length
        : null;
}

function validEthereumConfiguration(value) {
    const chainId = ownValue(value, "chainId");
    const results = ownValue(value, "results");
    const count = boundedArrayLength(results);
    if (!BigWalletBridgeWire.isCanonicalEthereumChainId(chainId) ||
        count === null) {
        return false;
    }
    for (let index = 0; index < count; index += 1) {
        if (!hasOwn(results, index) || typeof results[index] !== "string") {
            return false;
        }
    }
    return true;
}

function validSolanaPublicKey(value) {
    if (typeof value !== "string" || value.length === 0) { return false; }
    try {
        return Base58.decode(value).length === 32;
    } catch {
        return false;
    }
}

function validSolanaConfiguration(value) {
    const publicKey = ownValue(value, "publicKey");
    if (!validSolanaPublicKey(publicKey)) { return false; }
    const revision = ownValue(value, "accountRevision");
    const epoch = ownValue(value, "solanaAuthorizationEpoch");
    const connected = ownValue(value, "isConnected");
    return (typeof revision === "undefined" ||
            isSafeIntegerNormally(revision) && revision >= 0) &&
        (typeof epoch === "undefined" ||
            isSafeIntegerNormally(epoch) && epoch >= 0) &&
        (typeof connected === "undefined" || typeof connected === "boolean");
}

function sessionUUID() {
    try {
        const randomUUID = window.crypto?.randomUUID;
        if (typeof randomUUID === "function") {
            return applyFunction(randomUUID, window.crypto, []);
        }
    } catch {
    }
    const bytes = new Uint8Array(16);
    try {
        window.crypto.getRandomValues(bytes);
    } catch {
        for (let index = 0; index < bytes.length; index += 1) {
            bytes[index] = Math.floor(Math.random() * 256);
        }
    }
    bytes[6] = (bytes[6] & 15) | 64;
    bytes[8] = (bytes[8] & 63) | 128;
    const hex = [];
    for (let index = 0; index < bytes.length; index += 1) {
        hex[index] = bytes[index].toString(16).padStart(2, "0");
    }
    return `${hex.slice(0, 4).join("")}-${hex.slice(4, 6).join("")}-` +
        `${hex.slice(6, 8).join("")}-${hex.slice(8, 10).join("")}-` +
        hex.slice(10).join("");
}

const installedGeneration = ownValue(window, "bigWalletInstallingProviderGeneration");
try { delete window.bigWalletInstallingProviderGeneration; } catch {}
const previousSerial = ownValue(window, "bigWalletInpageProviderGenerationSerial");
const generationSerial = isSafeIntegerNormally(previousSerial) &&
    previousSerial >= 0 && previousSerial < Number.MAX_SAFE_INTEGER
    ? previousSerial + 1
    : 1;
const generation = typeof installedGeneration === "string"
    ? installedGeneration
    : `inpage:${generationSerial}`;

const reusableAnchor = trustedStableFacadeAnchor();
const reusableFacades = ownValue(reusableAnchor, "record");
const stableFacades = reusableFacades || createStableFacadeRecord({
    icon: bigWalletIcon,
    uuid: sessionUUID(),
});
const facadeSnapshots = reusableFacades
    ? stableFacades.snapshots()
    : {ethereum: null, solana: null};
const initialSnapshots = freezeObjectNormally({
    ethereum: facadeSnapshots.ethereum,
    solana: facadeSnapshots.solana,
});
ensureStableFacadeAnchor(stableFacades, initialSnapshots);
const previousPhantom = ownValue(window, "phantom");
let committed = false;
let ethereumProvider;
let solanaProvider;
let responseIngressEpoch = 0;

function ingressIsCurrent(epoch) {
    return epoch === responseIngressEpoch;
}

function isCurrentInstallation() {
    return committed &&
        ownValue(window, "bigWalletInpageProviderGenerationToken") === generation &&
        ownValue(window, contentHandlerProperty) === handleContentBridgeMessage;
}

function postToPage(message) {
    if (!isCurrentInstallation()) { return false; }
    applyFunction(postWindowMessageNormally, window, [message, "*"]);
    return isCurrentInstallation();
}

const transport = Object.freeze({
    isCurrent: isCurrentInstallation,
    postRequest(message) {
        if (!message || typeof message !== "object") { return false; }
        const provider = ownValue(message, "provider");
        const id = ownValue(message, "id");
        const name = ownValue(message, "name");
        let body;
        if (provider === "ethereum") {
            body = {
                accountRevision: ownValue(message, "accountRevision"),
                address: ownValue(message, "address"),
                chainId: ownValue(message, "chainId"),
                object: ownValue(message, "data"),
            };
        } else if (provider === "solana") {
            body = ownValue(message, "body");
        } else {
            return false;
        }
        const envelope = {
            direction: PAGE_TO_CONTENT_DIRECTION,
            kind: "request",
            message: {body, id, name, provider},
            providerGeneration: generation,
        };
        if (provider === "solana") {
            const epoch = ownValue(message, "solanaAuthorizationEpoch");
            if (isSafeIntegerNormally(epoch) && epoch >= 0) {
                envelope.solanaAuthorizationEpoch = epoch;
            }
        }
        return postToPage(envelope);
    },
    postRPC(message, messageGeneration) {
        if (messageGeneration !== generation) { return false; }
        return postToPage({
            direction: PAGE_TO_CONTENT_DIRECTION,
            kind: "rpc",
            message,
            providerGeneration: generation,
        });
    },
    postDisconnect(message) {
        if (!message || typeof message !== "object") { return false; }
        const provider = ownValue(message, "provider");
        if (provider !== "ethereum" && provider !== "solana") { return false; }
        const request = {provider, subject: "disconnect"};
        const id = ownValue(message, "id");
        if (typeof id !== "undefined") { request.id = id; }
        const envelope = {
            direction: PAGE_TO_CONTENT_DIRECTION,
            kind: "disconnect",
            message: request,
            providerGeneration: generation,
        };
        if (provider === "solana") {
            const epoch = ownValue(message, "solanaAuthorizationEpoch");
            if (isSafeIntegerNormally(epoch) && epoch >= 0) {
                envelope.solanaAuthorizationEpoch = epoch;
            }
        }
        return postToPage(envelope);
    },
    synchronizeSolanaEpoch(epoch) {
        if (!isSafeIntegerNormally(epoch) || epoch < 0) { return false; }
        return postToPage({
            direction: PAGE_TO_CONTENT_DIRECTION,
            kind: "solanaAuthorizationEpoch",
            providerGeneration: generation,
            solanaAuthorizationEpoch: epoch,
        });
    },
});

function malformedError() {
    return {code: -32603, message: "Failed to process provider response"};
}

function canonicalError(response) {
    const rawError = ownValue(response, "error");
    let code;
    let data;
    let message;
    if (rawError && typeof rawError === "object") {
        code = ownValue(rawError, "code");
        message = ownValue(rawError, "message");
        data = ownValue(rawError, "data");
    } else if (typeof rawError === "string") {
        message = rawError;
    }
    const topCode = ownValue(response, "errorCode");
    if (!Number.isFinite(code) && Number.isFinite(topCode)) { code = topCode; }
    if (typeof data === "undefined") {
        data = decodeProviderErrorData(ownValue(response, "errorDataJSON"));
    }
    if (typeof data === "undefined") {
        const signature = ownValue(response, "errorSignature");
        if (typeof signature === "string") { data = {signature}; }
    }
    const error = {
        code: Number.isFinite(code) ? code : -32603,
        message: typeof message === "string"
            ? message
            : "Failed to process provider response",
    };
    if (typeof data !== "undefined") { error.data = data; }
    return error;
}

function applyCanonical(providerName, envelope) {
    try {
        return providerName === "ethereum"
            ? BigWalletEthereum.applyEnvelope(ethereumProvider, envelope)
            : BigWalletSolana.applyEnvelope(solanaProvider, envelope);
    } catch {
        return false;
    }
}

function currentSnapshot(providerName) {
    return providerName === "ethereum"
        ? BigWalletEthereum.snapshot(ethereumProvider)
        : BigWalletSolana.snapshot(solanaProvider);
}

function configurationFor(providerName, value, switchAccount = false) {
    const current = currentSnapshot(providerName) || {};
    const reauthorizationRevision = ownValue(value, "reauthorizationRevision");
    const reauthorization = isSafeIntegerNormally(reauthorizationRevision) &&
        reauthorizationRevision >= 0 ? {reauthorizationRevision} : {};
    if (hasOwn(reauthorization, "reauthorizationRevision")) {
        switchAccount = reauthorizationRevision > (current.reauthorizationRevision || 0);
    }
    if (providerName === "ethereum") {
        const results = ownValue(value, "results");
        const configuredAddress = ownValue(value, "address");
        const address = isArrayNormally(results) && typeof results[0] === "string"
            ? results[0]
            : typeof configuredAddress === "string" ? configuredAddress : "";
        const configuredChainId = ownValue(value, "chainId");
        return {
            ...reauthorization,
            address,
            chainId: typeof configuredChainId === "string"
                ? configuredChainId
                : typeof current.chainId === "string" ? current.chainId : "0x1",
        };
    }
    const configuredKey = ownValue(value, "publicKey");
    const publicKey = typeof configuredKey === "string" ? configuredKey : null;
    const revision = ownValue(value, "accountRevision");
    const epoch = ownValue(value, "solanaAuthorizationEpoch");
    const connected = ownValue(value, "isConnected");
    const currentRevision = isSafeIntegerNormally(current.accountRevision) &&
        current.accountRevision >= 0
        ? current.accountRevision
        : 0;
    const changesAccount = switchAccount || publicKey !== current.publicKey;
    if (changesAccount && currentRevision === Number.MAX_SAFE_INTEGER) {
        return null;
    }
    const minimumRevision = changesAccount
        ? currentRevision + 1
        : currentRevision;
    return {
        ...reauthorization,
        accountRevision: isSafeIntegerNormally(revision) && revision >= 0
            ? Math.max(revision, minimumRevision)
            : minimumRevision,
        isConnected: typeof connected === "boolean"
            ? connected && publicKey !== null
            : publicKey !== null,
        publicKey,
        solanaAuthorizationEpoch: isSafeIntegerNormally(epoch) && epoch >= 0
            ? epoch
            : isSafeIntegerNormally(current.solanaAuthorizationEpoch)
                ? current.solanaAuthorizationEpoch : 0,
    };
}

function deliverConfiguration(
    providerName,
    value,
    switchAccount,
    suppressUpdate,
    ingressEpoch
) {
    if (!ingressIsCurrent(ingressEpoch)) {
        return {configuration: null, delivered: false};
    }
    const current = providerName === "solana"
        ? currentSnapshot("solana")
        : null;
    const configuration = configurationFor(
        providerName,
        value || {},
        switchAccount
    );
    if (!ingressIsCurrent(ingressEpoch)) {
        return {configuration: null, delivered: false};
    }
    if (providerName === "solana" &&
        suppressUpdate !== true &&
        (configuration === null ||
            (configuration.publicKey === null &&
                (typeof current?.publicKey === "string" ||
                    current?.isConnected === true)))) {
        try {
            solanaProvider.externalDisconnect();
        } catch {
        }
        if (!ingressIsCurrent(ingressEpoch)) {
            return {configuration: null, delivered: true};
        }
        const disconnected = currentSnapshot("solana");
        if (!disconnected) {
            return {configuration: null, delivered: false};
        }
        const disconnectedConfiguration = {
            accountRevision: disconnected.accountRevision,
            isConnected: false,
            publicKey: null,
            solanaAuthorizationEpoch:
                disconnected.solanaAuthorizationEpoch,
        };
        return {
            configuration: disconnectedConfiguration,
            delivered: applyCanonical(providerName, {
                configuration: disconnectedConfiguration,
                kind: "configuration",
                suppressUpdate: false,
                switchAccount,
            }),
        };
    }
    return {
        configuration,
        delivered: applyCanonical(providerName, {
            configuration,
            kind: "configuration",
            suppressUpdate,
            switchAccount,
        }),
    };
}

function configurationMap(values) {
    const length = boundedArrayLength(values);
    if (length === null) { return null; }
    const result = {ethereum: null, solana: null};
    for (let index = 0; index < length; index += 1) {
        if (!hasOwn(values, index)) { return null; }
        const value = values[index];
        if (!value || typeof value !== "object") { return null; }
        const provider = ownValue(value, "provider");
        if ((provider !== "ethereum" && provider !== "solana") ||
            result[provider] !== null) {
            return null;
        }
        if (provider === "ethereum"
            ? !validEthereumConfiguration(value)
            : !validSolanaConfiguration(value)) {
            return null;
        }
        result[provider] = value;
    }
    return result;
}

function terminalMatchesConfiguration(providerName, response, configuration) {
    if (!configuration || ownValue(response, "provider") !== providerName) {
        return false;
    }
    const name = ownValue(response, "name");
    if (providerName === "ethereum") {
        if (name === "requestAccounts") {
            const results = ownValue(response, "results");
            const configured = ownValue(configuration, "results");
            if (!isArrayNormally(results) || !isArrayNormally(configured)) {
                return false;
            }
            const result = typeof results[0] === "string"
                ? results[0].toLowerCase()
                : "";
            const address = typeof configured[0] === "string"
                ? configured[0].toLowerCase()
                : "";
            return result === address;
        }
        return (name === "switchEthereumChain" ||
                name === "addEthereumChain") &&
            ownValue(response, "chainId") ===
                ownValue(configuration, "chainId");
    }
    if (name !== "connect") { return false; }
    let result = ownValue(response, "publicKey");
    if (typeof result !== "string") {
        const value = ownValue(response, "result");
        result = typeof value === "string"
            ? value
            : ownValue(value, "publicKey");
    }
    return typeof result === "string" &&
        result === ownValue(configuration, "publicKey");
}

function deliverConfigurations(response, suppressUpdate, ingressEpoch) {
    const valuesDescriptor = descriptor(response, "latestConfigurations");
    if (!valuesDescriptor) { return undefined; }
    if (!("value" in valuesDescriptor)) {
        return malformedConfigurationDelivery;
    }
    const configurations = configurationMap(valuesDescriptor.value);
    if (!configurations) { return malformedConfigurationDelivery; }
    const delivery = {
        applied: {ethereum: false, solana: false},
        delivered: false,
    };
    if (!ingressIsCurrent(ingressEpoch)) { return delivery; }
    const switchAccount = ownValue(response, "name") === "switchAccount" &&
        (ownValue(response, "provider") === "unknown" ||
            ownValue(response, "provider") === "multiple");
    if (!ingressIsCurrent(ingressEpoch)) {
        delivery.delivered = true;
        return delivery;
    }
    let providerDelivery = deliverConfiguration(
        "ethereum",
        configurations.ethereum,
        switchAccount,
        suppressUpdate,
        ingressEpoch
    );
    delivery.applied.ethereum = terminalMatchesConfiguration(
        "ethereum",
        response,
        configurations.ethereum
    );
    delivery.delivered = providerDelivery.delivered;
    if (!ingressIsCurrent(ingressEpoch)) { return delivery; }
    providerDelivery = deliverConfiguration(
        "solana",
        configurations.solana,
        switchAccount,
        suppressUpdate,
        ingressEpoch
    );
    delivery.applied.solana = terminalMatchesConfiguration(
        "solana",
        response,
        configurations.solana
    );
    delivery.delivered = providerDelivery.delivered || delivery.delivered;
    return delivery;
}

function canonicalSuccess(
    providerName,
    id,
    name,
    response,
    suppressUpdate,
    configurationApplied,
    approvalCommitted
) {
    const hasResult = hasOwn(response, "result");
    const hasResults = hasOwn(response, "results");
    const hasPublicKey = providerName === "solana" && hasOwn(response, "publicKey");
    if (Number(hasResult) + Number(hasResults) + Number(hasPublicKey) !== 1) {
        return {error: malformedError(), id, kind: "error", name, suppressUpdate};
    }
    if (hasResults) {
        return providerName === "solana"
            ? {
                id,
                kind: "batchResult",
                name,
                results: ownValue(response, "results"),
                suppressUpdate,
                configurationApplied,
                approvalCommitted,
            }
            : {
                id,
                kind: "result",
                name,
                result: ownValue(response, "results"),
                suppressUpdate,
                configurationApplied,
                approvalCommitted,
            };
    }
    return {
        id,
        kind: "result",
        name,
        result: hasPublicKey
            ? {publicKey: ownValue(response, "publicKey")}
            : ownValue(response, "result"),
        suppressUpdate,
        configurationApplied,
        approvalCommitted,
    };
}

function providerForWireId(id) {
    if (!isSafeIntegerNormally(id) || id <= 0) { return null; }
    return id % 2 === 1 ? "ethereum" : "solana";
}

function rejectMalformedCorrelation(id, name, suppressUpdate, ingressEpoch) {
    const providerName = providerForWireId(id);
    if (!providerName) { return false; }
    return applyCanonical(providerName, {
        error: malformedError(),
        id,
        kind: "error",
        name,
        suppressUpdate: suppressUpdate || !ingressIsCurrent(ingressEpoch),
    });
}

function deliverDirect(
    response,
    inheritedId,
    inheritedName,
    suppressUpdate,
    appliedConfigurations,
    ingressEpoch
) {
    if (!response || typeof response !== "object") { return false; }
    const claimedProvider = ownValue(response, "provider");
    const hasOwnId = hasOwn(response, "id");
    const ownId = ownValue(response, "id");
    if (hasOwnId &&
        (!isSafeIntegerNormally(ownId) ||
            (isSafeIntegerNormally(inheritedId) && ownId !== inheritedId))) {
        return isSafeIntegerNormally(inheritedId)
            ? rejectMalformedCorrelation(
                inheritedId,
                inheritedName,
                suppressUpdate,
                ingressEpoch
            )
            : false;
    }
    const id = hasOwnId ? ownId : inheritedId;
    const ownName = ownValue(response, "name");
    const name = typeof ownName === "string" ? ownName : inheritedName;
    if (name === "didLoadLatestConfiguration" || name === "switchAccount") {
        if (claimedProvider !== "ethereum" && claimedProvider !== "solana") {
            return isSafeIntegerNormally(id)
                ? rejectMalformedCorrelation(
                    id,
                    name,
                    suppressUpdate,
                    ingressEpoch
                )
                : false;
        }
        if (claimedProvider === "ethereum"
            ? !validEthereumConfiguration(response)
            : !validSolanaConfiguration(response)) {
            return false;
        }
        return deliverConfiguration(
            claimedProvider,
            response,
            name === "switchAccount",
            suppressUpdate,
            ingressEpoch
        ).delivered;
    }
    if (!isSafeIntegerNormally(id)) { return false; }
    const providerName = providerForWireId(id);
    if (!providerName || claimedProvider !== providerName) {
        return rejectMalformedCorrelation(
            id,
            name,
            suppressUpdate,
            ingressEpoch
        );
    }
    let canonical;
    if (hasOwn(response, "error")) {
        if (hasOwn(response, "result") || hasOwn(response, "results") ||
            hasOwn(response, "publicKey")) {
            canonical = {
                error: malformedError(),
                id,
                kind: "error",
                name,
                suppressUpdate,
            };
        } else {
            const error = canonicalError(response);
            canonical = {
                authorizationFailure:
                    ownValue(response, ETHEREUM_AUTHORIZATION_FAILURE_KEY) ===
                        ETHEREUM_AUTHORIZATION_FAILURE_VERSION ||
                    (providerName === "solana" && error.code === 4100 &&
                        typeof ownValue(response, "errorPublicKey") === "string"),
                error,
                id,
                kind: "error",
                name,
                revokeLocally: ownValue(response, "revokeLocally") === true,
                suppressUpdate,
            };
        }
    } else {
        const appliedConfiguration = appliedConfigurations?.[providerName];
        canonical = canonicalSuccess(
            providerName,
            id,
            name,
            response,
            suppressUpdate,
            appliedConfiguration,
            ownValue(response, APPROVAL_COMMITTED_KEY) === true
        );
    }
    if (!ingressIsCurrent(ingressEpoch)) {
        canonical.suppressUpdate = true;
    }
    return applyCanonical(providerName, canonical);
}

function deliverMultiple(
    id,
    response,
    suppressUpdate,
    appliedConfigurations,
    ingressEpoch
) {
    const bodies = ownValue(response, "bodies");
    const count = boundedArrayLength(bodies);
    if (count === null) { return false; }
    const name = ownValue(response, "name");
    let delivered = false;
    for (let index = 0; index < count; index += 1) {
        if (hasOwn(bodies, index)) {
            delivered = deliverDirect(
                bodies[index],
                id,
                name,
                suppressUpdate,
                appliedConfigurations,
                ingressEpoch
            ) || delivered;
        }
    }
    if (suppressUpdate) { return delivered; }
    const disconnect = ownValue(response, "providersToDisconnect");
    const disconnectCount = boundedArrayLength(disconnect);
    if (disconnectCount === null) { return delivered; }
    for (let index = 0; index < disconnectCount; index += 1) {
        if (!ingressIsCurrent(ingressEpoch)) { return delivered; }
        if (!hasOwn(disconnect, index)) { continue; }
        const providerName = disconnect[index];
        if (!ingressIsCurrent(ingressEpoch)) { return delivered; }
        if (providerName === "solana") {
            try {
                solanaProvider.externalDisconnect();
                delivered = true;
            } catch {
            }
        } else if (providerName === "ethereum") {
            delivered = deliverConfiguration(
                providerName,
                {},
                true,
                false,
                ingressEpoch
            ).delivered || delivered;
        }
    }
    return delivered;
}

function handleContentBridgeMessage(event) {
    const previousIngressEpoch = responseIngressEpoch;
    let data;
    let source;
    try {
        data = event.data;
        source = event.source;
    } catch {
        return;
    }
    if (source !== window || !data ||
        ownValue(data, "direction") !== CONTENT_TO_PAGE_DIRECTION ||
        ownValue(data, "providerGeneration") !== generation ||
        !isCurrentInstallation()) {
        return;
    }
    const kind = ownValue(data, "kind");
    if (kind === "configurationError") {
        if (hasExactKeys(data, [
                "direction", "kind", "providerGeneration",
            ])) {
            const error = {
                code: 4900,
                message: "Failed to communicate with Big Wallet",
            };
            applyCanonical("ethereum", {kind, error});
            applyCanonical("solana", {kind, error});
        }
        return;
    }
    const response = ownValue(data, "response");
    const id = ownValue(data, "id");
    const suppressUpdate = ownValue(data, "suppressProviderUpdate") === true;
    let normalizedRPC = null;
    if (kind === "rpc") {
        normalizedRPC = normalizedRPCResponse(response, id);
        if (!normalizedRPC) { return; }
    } else if (kind !== "response" || !response ||
        typeof response !== "object" ||
        ownValue(response, "configurationReadFailed") === true) {
        return;
    }
    let ingressEpoch = previousIngressEpoch;
    let reservedIngress = false;
    if (responseIngressEpoch === previousIngressEpoch) {
        if (previousIngressEpoch === Number.MAX_SAFE_INTEGER) { return; }
        ingressEpoch = previousIngressEpoch + 1;
        responseIngressEpoch = ingressEpoch;
        reservedIngress = true;
    }
    const finishIngress = delivered => {
        if (reservedIngress && !delivered &&
            responseIngressEpoch === ingressEpoch) {
            responseIngressEpoch = previousIngressEpoch;
        }
    };
    let delivered = false;
    try {
        if (kind === "rpc") {
            if (providerForWireId(normalizedRPC.id) !== "ethereum") {
                delivered = rejectMalformedCorrelation(
                    normalizedRPC.id,
                    null,
                    suppressUpdate,
                    ingressEpoch
                );
            } else {
                delivered = applyCanonical(
                    "ethereum",
                    hasOwn(normalizedRPC, "result")
                        ? {
                            id: normalizedRPC.id,
                            kind: "result",
                            name: null,
                            result: normalizedRPC.result,
                            suppressUpdate: !ingressIsCurrent(ingressEpoch),
                        }
                        : {
                            error: normalizedRPC.error,
                            id: normalizedRPC.id,
                            kind: "error",
                            name: null,
                            suppressUpdate: !ingressIsCurrent(ingressEpoch),
                        }
                );
            }
            return;
        }
        const configurationDelivery = deliverConfigurations(
            response,
            suppressUpdate,
            ingressEpoch
        );
        if (configurationDelivery === malformedConfigurationDelivery) {
            const responseId = ownValue(response, "id");
            const correlationId = isSafeIntegerNormally(id)
                ? id
                : isSafeIntegerNormally(responseId) ? responseId : null;
            delivered = correlationId === null
                ? false
                : rejectMalformedCorrelation(
                    correlationId,
                    ownValue(response, "name"),
                    suppressUpdate,
                    ingressEpoch
                );
        } else if (typeof configurationDelivery !== "undefined") {
            delivered = configurationDelivery.delivered;
            const responseName = ownValue(response, "name");
            const responseProvider = ownValue(response, "provider");
            const appliedManualSwitch = responseName === "switchAccount" &&
                responseProvider === "multiple";
            if (typeof responseName === "string" &&
                !appliedManualSwitch &&
                (isSafeIntegerNormally(id) ||
                    isSafeIntegerNormally(ownValue(response, "id")))) {
                const terminalDelivered = responseProvider === "multiple"
                    ? deliverMultiple(
                        id,
                        response,
                        suppressUpdate,
                        configurationDelivery.applied,
                        ingressEpoch
                    )
                    : deliverDirect(
                        response,
                        id,
                        responseName,
                        suppressUpdate,
                        configurationDelivery.applied,
                        ingressEpoch
                    );
                delivered = terminalDelivered || delivered;
            }
        } else {
            const provider = ownValue(response, "provider");
            delivered = provider === "multiple"
                ? deliverMultiple(
                    id,
                    response,
                    suppressUpdate,
                    null,
                    ingressEpoch
                )
                : deliverDirect(
                    response,
                    id,
                    ownValue(response, "name"),
                    suppressUpdate,
                    null,
                    ingressEpoch
                );
        }
    } finally {
        finishIngress(delivered);
    }
}

function contentMessageTrampoline(event) {
    const handler = ownValue(window, contentHandlerProperty);
    if (typeof handler === "function") {
        try { applyFunction(handler, undefined, [event]); } catch {}
    }
}

function announceTrampoline() {
    const handler = ownValue(window, announceHandlerProperty);
    if (typeof handler === "function") {
        try { applyFunction(handler, undefined, []); } catch {}
    }
}

function retireTarget(target, error) {
    try {
        if (typeof target?.retire === "function") {
            applyFunction(target.retire, undefined, [error]);
        }
    } catch {}
}

function dispatchInitialized(name) {
    try { window.dispatchEvent(new Event(name)); } catch {}
}

ethereumProvider = new BigWalletEthereum(
    generation,
    transport,
    initialSnapshots.ethereum
);
solanaProvider = new BigWalletSolana(
    generation,
    transport,
    initialSnapshots.solana
);
const facadeTransaction = stableFacades.prepareTargets({
    ethereumProvider: Object.freeze({
        provider: ethereumProvider,
        requestConnectReplay: listener => ethereumRequestConnectReplay(
            ethereumProvider,
            listener
        ),
        retire: error => BigWalletEthereum.retire(ethereumProvider, error),
        snapshot: () => BigWalletEthereum.snapshot(ethereumProvider),
    }),
    solanaProvider: Object.freeze({
        provider: solanaProvider,
        retire: error => BigWalletSolana.retire(solanaProvider, error),
        snapshot: () => BigWalletSolana.snapshot(solanaProvider),
    }),
});
if (ownValue(window, contentSetupProperty) !== true) {
    applyFunction(addWindowEventListenerNormally, window, [
        "message",
        contentMessageTrampoline,
    ]);
}
if (ownValue(window, announceSetupProperty) !== true) {
    applyFunction(addWindowEventListenerNormally, window, [
        "eip6963:requestProvider",
        announceTrampoline,
    ]);
}
const phantom = previousPhantom && typeof previousPhantom === "object"
    ? previousPhantom
    : {};
defineProviderAlias(phantom, "solana", stableFacades.solana);
defineValue(window, "bigWalletInpageProviderGenerationSerial", generationSerial);
defineValue(window, "bigWalletInpageProviderGenerationToken", generation);
defineValue(window, "bigWalletInpageProviderGeneration", {});
defineValue(window, stableFacadeProperty, stableFacades);
defineValue(window, contentHandlerProperty, handleContentBridgeMessage);
defineValue(window, contentSetupProperty, true);
defineValue(window, announceHandlerProperty, () => stableFacades.announceEthereum());
defineValue(window, announceSetupProperty, true);
defineValue(window, "bigWalletInpageEIP6963ProviderState", stableFacades);
defineProviderAlias(window, "bigwallet", stableFacades.bigwallet);
defineProviderAlias(window, "ethereum", stableFacades.ethereum);
defineProviderAlias(window, "web3", stableFacades.web3);
defineProviderAlias(window, "metamask", stableFacades.ethereum);
defineProviderAlias(window, "solana", stableFacades.solana);
defineProviderAlias(window, "phantom", phantom);
committed = true;
const facadePreviousTargets = facadeTransaction.commit();
if (!facadePreviousTargets) { throw new Error("Facade commit failed"); }

const replacementError = providerReplacementError();
retireTarget(facadePreviousTargets.ethereum, replacementError);
retireTarget(facadePreviousTargets.solana, replacementError);
try { stableFacades.ensureWalletRegistration(); } catch {}
if (!reusableFacades) {
    try { stableFacades.announceEthereum(); } catch {}
}
dispatchInitialized("ethereum#initialized");
dispatchInitialized("solana#initialized");
