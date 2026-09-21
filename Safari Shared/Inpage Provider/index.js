// ∅ 2026 lil org

"use strict";

import {
    applyFunction,
    definePropertyNormally,
    freezeObjectNormally,
    getOwnPropertyDescriptorNormally,
    isSafeIntegerNormally,
} from "./intrinsics";

import BigWalletEthereum, {
    applyDecodedEnvelope as applyEthereumDecodedEnvelope,
    subscribeNotifications as ethereumSubscribeNotifications,
    withReadyState as ethereumWithReadyState,
} from "./ethereum";
import BigWalletSolana, {
    applyDecodedEnvelope as applySolanaDecodedEnvelope,
    observeConfiguration as observeSolanaConfiguration,
    subscribeNotifications as solanaSubscribeNotifications,
} from "./solana";
import {providerReplacementError} from "./error";
import {
    createStableFacadeRecord,
    reusableStableFacadeRecord,
    stableFacadeVersion,
} from "./stable_facades";
import BigWalletBridgeWire from "../Resources/bridge_wire";

const {
    CONTENT_TO_PAGE_DIRECTION,
    PAGE_TO_CONTENT_DIRECTION,
} = BigWalletBridgeWire;

const isFrozenNormally = Object.isFrozen;
const postWindowMessageNormally = window.postMessage;
const addWindowEventListenerNormally = window.addEventListener;
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

const transport = freezeObjectNormally({
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
        return postToPage(envelope);
    },
});

function malformedError() {
    return {code: -32603, message: "Failed to process provider response"};
}


function applyDecoded(providerName, envelope, configurationIsCurrent) {
    const delivery = freezeObjectNormally({
        __proto__: null,
        suppressUpdate: false,
        ...envelope,
    });
    try {
        return providerName === "ethereum"
            ? applyEthereumDecodedEnvelope(ethereumProvider, delivery)
            : applySolanaDecodedEnvelope(solanaProvider, delivery, configurationIsCurrent);
    } catch {
        return false;
    }
}

function ethereumConfiguration(value) {
    const current = BigWalletEthereum.snapshot(ethereumProvider) || {__proto__: null};
    const reauthorizationRevision = value?.reauthorizationRevision ??
        current.reauthorizationRevision ?? 0;
    return freezeObjectNormally({
        __proto__: null,
        reauthorizationRevision,
        address: value?.address ?? "",
        chainId: value?.chainId ?? current.chainId ?? "0x1",
    });
}

function deliverEthereumConfiguration(
    value,
    suppressUpdate,
    ingressEpoch
) {
    if (!ingressIsCurrent(ingressEpoch)) {
        return false;
    }
    const configuration = ethereumConfiguration(value);
    if (!ingressIsCurrent(ingressEpoch)) {
        return false;
    }
    return applyDecoded("ethereum", {
        configuration,
        kind: "configuration",
        suppressUpdate,
    });
}

function deliverConfigurations(response, suppressUpdate, ingressEpoch) {
    const state = response.state;
    if (!state) { return false; }
    if (!ingressIsCurrent(ingressEpoch)) { return false; }
    const solana = freezeObjectNormally({
        __proto__: null,
        kind: "configuration",
        configuration: state.solana,
        workerRevision: state.revisions.solana,
        suppressUpdate,
    });
    observeSolanaConfiguration(solanaProvider, solana);
    let delivered = deliverEthereumConfiguration(
        state.ethereum, suppressUpdate, ingressEpoch
    );
    if (!ingressIsCurrent(ingressEpoch)) { return delivered; }
    delivered = applyDecoded(
        "solana", solana, () => ingressIsCurrent(ingressEpoch)
    ) || delivered;
    return delivered;
}

function providerForWireId(id) {
    if (!isSafeIntegerNormally(id) || id <= 0) { return null; }
    return id % 2 === 1 ? "ethereum" : "solana";
}

function rejectMalformedCorrelation(id, name, suppressUpdate, ingressEpoch) {
    const providerName = providerForWireId(id);
    if (!providerName) { return false; }
    return applyDecoded(providerName, {
        error: malformedError(),
        id,
        kind: "error",
        name,
        suppressUpdate: suppressUpdate || !ingressIsCurrent(ingressEpoch),
    });
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
    if (kind !== "response" && kind !== "rpc") { return; }
    const raw = ownValue(data, "response");
    const id = ownValue(data, "id");
    const response = BigWalletBridgeWire.decodePageResponse(raw, id);
    const suppressUpdate = ownValue(data, "suppressProviderUpdate") === true;
    if (!response && !isSafeIntegerNormally(id)) { return; }
    let ingressEpoch = previousIngressEpoch;
    let reservedIngress = false;
    if (responseIngressEpoch === previousIngressEpoch) {
        if (previousIngressEpoch === Number.MAX_SAFE_INTEGER) { return; }
        ingressEpoch = previousIngressEpoch + 1;
        responseIngressEpoch = ingressEpoch;
        reservedIngress = true;
    }
    let delivered = false;
    try {
        if (!response) {
            delivered = rejectMalformedCorrelation(
                id, raw && typeof raw === "object" ? ownValue(raw, "name") : null,
                suppressUpdate, ingressEpoch
            );
            return;
        }
        if (kind === "rpc") {
            if ((response.kind !== "result" && response.kind !== "error") ||
                response.provider !== "ethereum" || response.name !== null ||
                providerForWireId(response.id) !== "ethereum" ||
                response.state !== null || response.configurationMatch !== null) {
                delivered = rejectMalformedCorrelation(id, null, true, ingressEpoch);
            } else {
                delivered = applyDecoded("ethereum", {
                    ...response,
                    suppressUpdate: true,
                    authorizationFailure: false,
                    approvalCommitted: false,
                });
            }
            return;
        }
        if (response.kind === "configurationError") {
            delivered = applyDecoded("ethereum", response);
            delivered = applyDecoded("solana", response) || delivered;
            return;
        }
        delivered = deliverConfigurations(response, suppressUpdate, ingressEpoch);
        if (response.kind === "configuration") { return; }
        if (providerForWireId(response.id) !== response.provider) {
            delivered = rejectMalformedCorrelation(
                response.id, response.name, suppressUpdate, ingressEpoch
            ) || delivered;
            return;
        }
        delivered = applyDecoded(response.provider, {
            ...response,
            suppressUpdate: suppressUpdate || !ingressIsCurrent(ingressEpoch),
        }) || delivered;
    } finally {
        if (reservedIngress && !delivered && responseIngressEpoch === ingressEpoch) {
            responseIngressEpoch = previousIngressEpoch;
        }
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
        subscribeNotifications: listener => ethereumSubscribeNotifications(
            ethereumProvider,
            listener
        ),
        withReadyState: listener => ethereumWithReadyState(
            ethereumProvider,
            listener
        ),
        retire: error => BigWalletEthereum.retire(ethereumProvider, error),
        snapshot: () => BigWalletEthereum.snapshot(ethereumProvider),
    }),
    solanaProvider: Object.freeze({
        provider: solanaProvider,
        subscribeNotifications: listener => solanaSubscribeNotifications(
            solanaProvider,
            listener
        ),
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
defineValue(window, stableFacadeProperty, stableFacades);
defineValue(window, contentHandlerProperty, handleContentBridgeMessage);
defineValue(window, contentSetupProperty, true);
defineValue(window, announceHandlerProperty, () => stableFacades.announceEthereum());
defineValue(window, announceSetupProperty, true);
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
