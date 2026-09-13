// ∅ 2026 lil org

"use strict";

import {
    applyFunction,
    createObjectNormally,
    definePropertyNormally,
    freezeObjectNormally,
    getOwnPropertyDescriptorNormally,
    isArrayNormally,
    MapConstructor,
    getWeakMapValue,
    setWeakMapValue,
    getMapEntry,
    setMapEntry,
} from "./intrinsics";

import OperationRuntime from "./operation_runtime";
import {
    outboundDataSnapshot,
    trustedOutboundArray,
    trustedOutboundRecord,
} from "./outbound_snapshot";
import Base58 from "./base58";
import Utils from "./utils";
import ProviderRpcError, {
    normalizeSolanaProviderError,
    providerReplacementError,
} from "./error";
import { walletName } from "./wallet_standard";
import { EventEmitter } from "events";

const walletStandardVersion = "1.0.0";
const solanaSignMessageFeatureVersion = "1.1.0";
const solanaMainnetChain = "solana:mainnet";
const solanaDevnetChain = "solana:devnet";
const solanaTestnetChain = "solana:testnet";
const solanaChains = Object.freeze([
    solanaMainnetChain,
    solanaDevnetChain,
    solanaTestnetChain,
]);
const solanaSupportedTransactionVersions = Object.freeze(["legacy", 0]);
const standardChangeEvent = "change";
const standardConnect = "standard:connect";
const standardDisconnect = "standard:disconnect";
const standardEvents = "standard:events";
const solanaSignAndSendTransaction = "solana:signAndSendTransaction";
const solanaSignTransaction = "solana:signTransaction";
const solanaSignMessage = "solana:signMessage";
const solanaAccountFeatures = Object.freeze([
    solanaSignAndSendTransaction,
    solanaSignTransaction,
    solanaSignMessage,
]);
const invalidSolanaMessageRequest =
    "Big Wallet could not normalize this Solana message request";
const invalidSolanaSignatureResponse =
    "Big Wallet received an invalid Solana signature response";
const invalidSolanaTransactionBatchRequest =
    "Big Wallet could not normalize this Solana transaction batch";
const invalidSolanaTransactionRequest =
    "Big Wallet could not normalize this Solana transaction request";
const invalidSolanaTransactionOptions =
    "Big Wallet received unsupported Solana transaction options";
const ambiguousSolanaTransactionParams =
    "Big Wallet received ambiguous Solana transaction params";
const mismatchedSolanaTransactionParams =
    "Big Wallet received mismatched Solana transaction params";
const mismatchedSolanaTransactionSignatures =
    "Big Wallet received mismatched Solana transaction signatures";
const providerNotReadyMessage = "provider is not ready";
const solanaSignatureApplicationError =
    "Big Wallet could not apply the Solana signature";
const unsupportedSolanaChain = "Big Wallet does not support this Solana chain";
const malformedSolanaResponse = "Failed to process Solana response";
const maximumTransactionBatchSize = 64;
const maximumCounter = Number.MAX_SAFE_INTEGER;
const emitNormally = EventEmitter.prototype.emit;
const addSetEntryNormally = Set.prototype.add;
const deleteSetEntryNormally = Set.prototype.delete;
const clearMapNormally = Map.prototype.clear;
const clearSetNormally = Set.prototype.clear;
const forEachSetNormally = Set.prototype.forEach;
const arrayBufferByteLengthNormally = getOwnPropertyDescriptorNormally(
    ArrayBuffer.prototype,
    "byteLength"
).get;
const getPrototypeOfNormally = Object.getPrototypeOf;
const isArrayBufferViewNormally = ArrayBuffer.isView;
const SetConstructor = Set;
const providerStates = new WeakMap;

function getProviderState(provider) {
    const state = getWeakMapValue(providerStates, provider);
    if (!state) {
        throw new TypeError("Invalid Solana provider");
    }
    return state;
}

function providerState(provider) {
    return getWeakMapValue(providerStates, provider);
}

function setProviderState(provider, state) {
    setWeakMapValue(providerStates, provider, state);
}

function addSetEntry(set, value) {
    applyFunction(addSetEntryNormally, set, [value]);
}

function deleteSetEntry(set, value) {
    return applyFunction(deleteSetEntryNormally, set, [value]);
}

function clearMap(map) {
    applyFunction(clearMapNormally, map, []);
}

function clearSet(set) {
    applyFunction(clearSetNormally, set, []);
}

function isArrayBuffer(value) {
    try {
        applyFunction(arrayBufferByteLengthNormally, value, []);
        return true;
    } catch {
        return false;
    }
}

function byteView(value) {
    try {
        if (isArrayBuffer(value)) {
            return new Uint8Array(value);
        }
        if (!isArrayBufferViewNormally(value) ||
            value.BYTES_PER_ELEMENT !== 1 ||
            typeof value.length !== "number") {
            return null;
        }
        return new Uint8Array(
            value.buffer,
            value.byteOffset,
            value.byteLength
        );
    } catch {
        return null;
    }
}

function isByteArray(value) {
    return byteView(value) !== null;
}

function bytesSnapshot(value, message) {
    const source = byteView(value);
    if (!source) {
        throw new ProviderRpcError(4200, message);
    }
    const snapshot = new Uint8Array(source.length);
    for (let index = 0; index < source.length; index += 1) {
        snapshot[index] = source[index];
    }
    return snapshot;
}

function signatureBytes(value) {
    let decoded;
    try {
        decoded = Base58.decode(value);
    } catch {
        throw new ProviderRpcError(4200, invalidSolanaSignatureResponse);
    }
    if (decoded.length !== 64) {
        throw new ProviderRpcError(4200, invalidSolanaSignatureResponse);
    }
    return decoded;
}

function validPublicKeyString(value) {
    if (typeof value !== "string" || value.length === 0) { return false; }
    try {
        return Base58.decode(value).length === 32;
    } catch {
        return false;
    }
}

function safePublicKeyString(value) {
    if (!value || typeof value.toString !== "function") { return null; }
    try {
        const stringValue = value.toString();
        return validPublicKeyString(stringValue) ? stringValue : null;
    } catch {
        return null;
    }
}

function ownDataDescriptor(value, name) {
    if (!value || (typeof value !== "object" && typeof value !== "function")) {
        return null;
    }
    const descriptor = getOwnPropertyDescriptorNormally(value, name);
    return descriptor && "value" in descriptor ? descriptor : null;
}

function emitProvider(provider, name, ...values) {
    try {
        applyFunction(emitNormally, provider, [name, ...values]);
    } catch {
    }
}

function emitStandardChange(provider, properties) {
    const state = getProviderState(provider);
    const listeners = [];
    applyFunction(forEachSetNormally, state.standardChangeListeners, [listener => {
        listeners[listeners.length] = listener;
    }]);
    for (let index = 0; index < listeners.length; index += 1) {
        try {
            listeners[index](properties);
        } catch {
        }
    }
}

class PublicKey {

    constructor(value) {
        if (!validPublicKeyString(value)) {
            throw new ProviderRpcError(4200, providerNotReadyMessage);
        }
        this.stringValue = value;
    }

    equals(publicKey) {
        return this.stringValue === safePublicKeyString(publicKey);
    }

    toBase58() {
        return this.stringValue;
    }

    toJSON() {
        return this.stringValue;
    }

    toBytes() {
        return this.toBuffer();
    }

    toBuffer() {
        return Base58.decode(this.stringValue);
    }

    toString() {
        return this.stringValue;
    }
}

function authorizationSnapshot(state) {
    return {
        accountRevision: state.accountRevision,
        publicKey: state.publicKey?.toString() || null,
        solanaAuthorizationEpoch: state.solanaAuthorizationEpoch,
    };
}

function authorizationMatches(state, authorization) {
    return !!authorization &&
        authorization.accountRevision === state.accountRevision &&
        authorization.publicKey === (state.publicKey?.toString() || null) &&
        authorization.solanaAuthorizationEpoch === state.solanaAuthorizationEpoch;
}

function incrementRevision(state) {
    if (state.accountRevision === maximumCounter) {
        throw new ProviderRpcError(-32603, "Solana account revision exhausted");
    }
    state.accountRevision += 1;
}

function advanceEpoch(state) {
    if (state.solanaAuthorizationEpoch === maximumCounter) {
        throw new ProviderRpcError(-32603, "Solana authorization epoch exhausted");
    }
    state.solanaAuthorizationEpoch += 1;
    return state.solanaAuthorizationEpoch;
}

function clearAuthorization(provider, tombstone, emitChanges = true) {
    const state = getProviderState(provider);
    const previousPublicKey = state.publicKey?.toString() || null;
    const wasConnected = state.isConnected;
    if (previousPublicKey !== null && state.accountRevision < maximumCounter) {
        state.accountRevision += 1;
    }
    state.publicKey = null;
    state.isConnected = false;
    state.accountRevocationTombstone = tombstone === true;
    clearMap(state.standardAccountsByAddress);
    if (!emitChanges) { return; }
    if (previousPublicKey !== null) {
        emitProvider(provider, "accountChanged", null);
        emitStandardChange(provider, {accounts: []});
    }
    if (wasConnected || previousPublicKey !== null) {
        emitProvider(provider, "disconnect");
    }
}

function operationIsCurrent(provider, record, approvalCommitted = false) {
    const state = getProviderState(provider);
    return state.runtime.owns(record) &&
        state.transport.isCurrent() === true &&
        (approvalCommitted ||
            authorizationMatches(state, record.metadata.authorization));
}

function requireAuthorization(provider, authorization) {
    const state = getProviderState(provider);
    if (state.runtime.phase === "retired" ||
        !authorizationMatches(state, authorization)) {
        throw providerReplacementError();
    }
}

function rejectOperation(provider, record, error) {
    const state = getProviderState(provider);
    return state.runtime.reject(
        record,
        error instanceof Error ? error : normalizeSolanaProviderError(error)
    );
}

function normalizedBase58Value(value, message) {
    if (typeof value === "string") {
        try {
            Base58.decode(value);
            return value;
        } catch {
            throw new ProviderRpcError(4200, message);
        }
    }
    return Base58.encode(bytesSnapshot(value, message));
}

function normalizedHexMessage(value) {
    if (typeof value !== "string") {
        return Utils.bufferToHex(bytesSnapshot(value, invalidSolanaMessageRequest));
    }
    const rawValue = value.startsWith("0x") ? value.slice(2) : value;
    if (rawValue.length % 2 !== 0 || !/^[0-9a-fA-F]*$/.test(rawValue)) {
        throw new ProviderRpcError(4200, invalidSolanaMessageRequest);
    }
    return `0x${rawValue}`;
}

function serializedMessage(adapter) {
    let value;
    try {
        value = applyFunction(
            adapter.serializeMessage,
            adapter.messageOwner,
            []
        );
    } catch {
        throw new ProviderRpcError(4200, invalidSolanaTransactionRequest);
    }
    return bytesSnapshot(value, invalidSolanaTransactionRequest);
}

function inheritedDataFunction(value, name) {
    let current = value;
    while (current) {
        const descriptor = getOwnPropertyDescriptorNormally(current, name);
        if (descriptor) {
            return "value" in descriptor && typeof descriptor.value === "function"
                ? descriptor.value
                : null;
        }
        current = getPrototypeOfNormally(current);
    }
    return null;
}

function capturedTransport(transport) {
    if (!transport || typeof transport !== "object") {
        throw new TypeError("Invalid Solana transport");
    }
    const isCurrentMethod = transport.isCurrent;
    const postRequestMethod = transport.postRequest;
    const postDisconnectMethod = transport.postDisconnect;
    const synchronizeEpochMethod = transport.synchronizeSolanaEpoch;
    if (typeof isCurrentMethod !== "function" ||
        typeof postRequestMethod !== "function" ||
        typeof postDisconnectMethod !== "function" ||
        typeof synchronizeEpochMethod !== "function") {
        throw new TypeError("Invalid Solana transport");
    }
    return freezeObjectNormally({
        isCurrent() {
            return applyFunction(isCurrentMethod, transport, []);
        },
        postRequest(message) {
            return applyFunction(postRequestMethod, transport, [message]);
        },
        postDisconnect(message) {
            return applyFunction(postDisconnectMethod, transport, [message]);
        },
        synchronizeSolanaEpoch(epoch) {
            return applyFunction(synchronizeEpochMethod, transport, [epoch]);
        },
    });
}

function transactionAdapter(transaction, message = invalidSolanaTransactionRequest) {
    if (!transaction || typeof transaction !== "object") {
        throw new ProviderRpcError(4200, message);
    }
    const messageDescriptor = ownDataDescriptor(transaction, "message");
    const versionedMessage = messageDescriptor?.value;
    const headerDescriptor = ownDataDescriptor(versionedMessage, "header");
    const keysDescriptor = ownDataDescriptor(versionedMessage, "staticAccountKeys") ??
        ownDataDescriptor(versionedMessage, "accountKeys");
    const versionedSerialize = inheritedDataFunction(versionedMessage, "serialize");
    const requiredSignatures = headerDescriptor?.value?.numRequiredSignatures;
    if (headerDescriptor && keysDescriptor &&
        isArrayNormally(keysDescriptor.value) &&
        Number.isSafeInteger(requiredSignatures) &&
        requiredSignatures > 0 &&
        requiredSignatures <= keysDescriptor.value.length &&
        typeof versionedSerialize === "function") {
        const adapter = {
            messageOwner: versionedMessage,
            serializeMessage: versionedSerialize,
            staticAccountKeys: keysDescriptor.value,
            transaction,
            type: "versioned",
            requiredSignatures,
        };
        adapter.message = Base58.encode(serializedMessage(adapter));
        const signaturesDescriptor = ownDataDescriptor(transaction, "signatures");
        if (!signaturesDescriptor ||
            !isArrayNormally(signaturesDescriptor.value) ||
            requiredSignatures > signaturesDescriptor.value.length) {
            throw new ProviderRpcError(4200, message);
        }
        adapter.signatures = signaturesDescriptor.value;
        return adapter;
    }
    const serializeMessage = inheritedDataFunction(transaction, "serializeMessage");
    if (typeof serializeMessage !== "function") {
        throw new ProviderRpcError(4200, message);
    }
    const adapter = {
        messageOwner: transaction,
        serializeMessage,
        transaction,
        type: "legacy",
    };
    adapter.message = Base58.encode(serializedMessage(adapter));
    const signaturesDescriptor = ownDataDescriptor(transaction, "signatures");
    if (!signaturesDescriptor || !isArrayNormally(signaturesDescriptor.value)) {
        throw new ProviderRpcError(4200, message);
    }
    const signatures = signaturesDescriptor.value;
    adapter.signatures = signatures;
    if (signatures.length === 0) {
        throw new ProviderRpcError(4200, message);
    }
    for (let index = 0; index < signatures.length; index += 1) {
        const entry = signatures[index];
        const publicKeyDescriptor = ownDataDescriptor(entry, "publicKey");
        const signatureDescriptor = ownDataDescriptor(entry, "signature");
        if (!publicKeyDescriptor || !signatureDescriptor ||
            !signatureDescriptor.writable ||
            !safePublicKeyString(publicKeyDescriptor.value) ||
            (signatureDescriptor.value !== null &&
                !isByteArray(signatureDescriptor.value))) {
            throw new ProviderRpcError(4200, message);
        }
    }
    return adapter;
}

function transactionSerializerMatches(adapter) {
    const method = adapter.type === "versioned"
        ? "serialize"
        : "serializeMessage";
    return inheritedDataFunction(adapter.messageOwner, method) ===
        adapter.serializeMessage;
}

function transactionMessageMatches(adapter) {
    try {
        if (!transactionSerializerMatches(adapter)) { return false; }
        if (adapter.type === "versioned") {
            const descriptor = ownDataDescriptor(
                adapter.transaction,
                "message"
            );
            if (!descriptor || descriptor.value !== adapter.messageOwner) {
                return false;
            }
        }
        const message = Base58.encode(serializedMessage(adapter));
        if (!transactionSerializerMatches(adapter)) { return false; }
        if (adapter.type === "versioned") {
            const descriptor = ownDataDescriptor(
                adapter.transaction,
                "message"
            );
            if (!descriptor || descriptor.value !== adapter.messageOwner) {
                return false;
            }
        }
        return message === adapter.message;
    } catch {
        return false;
    }
}

function transactionMessagesMatch(adapters) {
    for (let index = 0; index < adapters.length; index += 1) {
        if (!transactionMessageMatches(adapters[index])) { return false; }
    }
    return true;
}

function signerPlan(adapter, publicKey, signature) {
    if (adapter.transaction.signatures !== adapter.signatures) {
        throw new ProviderRpcError(4200, solanaSignatureApplicationError);
    }
    if (adapter.type === "versioned") {
        let index = -1;
        for (let candidate = 0;
            candidate < adapter.requiredSignatures;
            candidate += 1) {
            if (safePublicKeyString(adapter.staticAccountKeys[candidate]) === publicKey) {
                index = candidate;
                break;
            }
        }
        if (index < 0 || index >= adapter.signatures.length) {
            throw new ProviderRpcError(4200, solanaSignatureApplicationError);
        }
        const descriptor = getOwnPropertyDescriptorNormally(
            adapter.signatures,
            `${index}`
        );
        if (!descriptor || !("value" in descriptor) || !descriptor.writable ||
            !isByteArray(descriptor.value)) {
            throw new ProviderRpcError(4200, solanaSignatureApplicationError);
        }
        return {
            target: adapter.signatures,
            property: `${index}`,
            originalDescriptor: descriptor,
            replacement: new Uint8Array(signature),
        };
    }
    for (let index = 0; index < adapter.signatures.length; index += 1) {
        const entry = adapter.signatures[index];
        const publicKeyDescriptor = ownDataDescriptor(entry, "publicKey");
        const signatureDescriptor = ownDataDescriptor(entry, "signature");
        if (safePublicKeyString(publicKeyDescriptor?.value) === publicKey) {
            if (!signatureDescriptor?.writable) {
                throw new ProviderRpcError(4200, solanaSignatureApplicationError);
            }
            return {
                target: entry,
                property: "signature",
                originalDescriptor: signatureDescriptor,
                replacement: signature,
            };
        }
    }
    throw new ProviderRpcError(4200, solanaSignatureApplicationError);
}

function restoreSignatureWrites(writes) {
    for (let index = writes.length - 1; index >= 0; index -= 1) {
        const write = writes[index];
        try {
            if (ownDataDescriptor(write.target, write.property)?.value ===
                write.replacement) {
                definePropertyNormally(
                    write.target,
                    write.property,
                    write.originalDescriptor
                );
            }
        } catch {
        }
    }
}

function applySignerPlan(plan) {
    definePropertyNormally(plan.target, plan.property, {
        ...plan.originalDescriptor,
        value: plan.replacement,
    });
}

function normalizedTransactionBatch(transactions, message) {
    if (!isArrayNormally(transactions) || transactions.length === 0 ||
        transactions.length > maximumTransactionBatchSize) {
        throw new ProviderRpcError(4200, message);
    }
    const adapters = [];
    for (let index = 0; index < transactions.length; index += 1) {
        adapters[index] = transactionAdapter(transactions[index], message);
    }
    return adapters;
}

function normalizedMessages(values, message) {
    if (!isArrayNormally(values) || values.length === 0 ||
        values.length > maximumTransactionBatchSize) {
        throw new ProviderRpcError(4200, message);
    }
    const messages = [];
    for (let index = 0; index < values.length; index += 1) {
        definePropertyNormally(messages, index, {
            configurable: true,
            enumerable: true,
            value: normalizedBase58Value(values[index], message),
            writable: true,
        });
    }
    return messages;
}

function messagePayload(message) {
    const payload = {message};
    return typeof message === "string"
        ? trustedOutboundRecord(payload)
        : outboundDataSnapshot(payload);
}

function messagesPayload(messages) {
    for (let index = 0; index < messages.length; index += 1) {
        if (typeof messages[index] !== "string") {
            return outboundDataSnapshot({messages});
        }
    }
    return trustedOutboundRecord({messages: trustedOutboundArray(messages)});
}

function createMetadata(method) {
    return {
        adapters: null,
        authorization: null,
        dispatched: false,
        messages: null,
        method,
        respondWithBuffer: false,
    };
}

function normalizeRequest(method, params) {
    const metadata = createMetadata(method);
    let normalizedParams;
    switch (method) {
        case "connect":
            normalizedParams = typeof params === "undefined"
                ? undefined
                : outboundDataSnapshot(params);
            break;
        case "signMessage": {
            const raw = params || {};
            if (!("message" in raw)) {
                throw new ProviderRpcError(4200, invalidSolanaMessageRequest);
            }
            const signsUTF8 = typeof raw.message === "string" &&
                typeof raw.display === "string" &&
                raw.display.toLowerCase() === "utf8";
            const message = signsUTF8
                ? raw.message
                : normalizedHexMessage(raw.message);
            const snapshot = outboundDataSnapshot(raw);
            snapshot.message = message;
            snapshot.messageEncoding = signsUTF8 ? "utf8" : "hex";
            normalizedParams = snapshot;
            metadata.messages = [snapshot.message];
            metadata.respondWithBuffer = true;
            break;
        }
        case "signTransaction": {
            const raw = params || {};
            if (raw.transaction && typeof raw.transaction === "object" &&
                !isByteArray(raw.transaction)) {
                const adapter = transactionAdapter(raw.transaction);
                const supplied = typeof raw.message === "undefined"
                    ? adapter.message
                    : normalizedBase58Value(
                        raw.message,
                        invalidSolanaTransactionRequest
                    );
                if (supplied !== adapter.message) {
                    throw new ProviderRpcError(
                        4200,
                        mismatchedSolanaTransactionParams
                    );
                }
                normalizedParams = messagePayload(adapter.message);
                metadata.adapters = [adapter];
                metadata.messages = [adapter.message];
            } else if (typeof raw.message !== "undefined") {
                const message = normalizedBase58Value(
                    raw.message,
                    invalidSolanaTransactionRequest
                );
                normalizedParams = messagePayload(message);
                metadata.messages = [message];
            } else {
                throw new ProviderRpcError(4200, invalidSolanaTransactionRequest);
            }
            break;
        }
        case "signAllTransactions": {
            const raw = params || {};
            const hasMessages = typeof raw.messages !== "undefined";
            const hasMessage = raw.message != null;
            if (hasMessages && hasMessage) {
                throw new ProviderRpcError(4200, ambiguousSolanaTransactionParams);
            }
            if (isArrayNormally(raw.transactions)) {
                const adapters = normalizedTransactionBatch(
                    raw.transactions,
                    invalidSolanaTransactionBatchRequest
                );
                const messages = [];
                for (let index = 0; index < adapters.length; index += 1) {
                    definePropertyNormally(messages, index, {
                        configurable: true,
                        enumerable: true,
                        value: adapters[index].message,
                        writable: true,
                    });
                }
                const suppliedValues = hasMessages
                    ? raw.messages
                    : hasMessage
                        ? raw.message
                        : messages;
                const supplied = normalizedMessages(
                    suppliedValues,
                    invalidSolanaTransactionBatchRequest
                );
                if (supplied.length !== messages.length) {
                    throw new ProviderRpcError(
                        4200,
                        mismatchedSolanaTransactionParams
                    );
                }
                for (let index = 0; index < messages.length; index += 1) {
                    if (messages[index] !== supplied[index]) {
                        throw new ProviderRpcError(
                            4200,
                            mismatchedSolanaTransactionParams
                        );
                    }
                }
                normalizedParams = messagesPayload(messages);
                metadata.adapters = adapters;
                metadata.messages = messages;
            } else {
                const values = hasMessages ? raw.messages : raw.message;
                const messages = normalizedMessages(
                    values,
                    invalidSolanaTransactionBatchRequest
                );
                normalizedParams = messagesPayload(messages);
                metadata.messages = messages;
            }
            break;
        }
        case "signAndSendTransaction": {
            const raw = params || {};
            if (typeof raw.transaction === "undefined" &&
                typeof raw.message === "undefined") {
                throw new ProviderRpcError(4200, invalidSolanaTransactionRequest);
            }
            let transaction;
            if (typeof raw.transaction === "object" &&
                raw.transaction !== null && !isByteArray(raw.transaction)) {
                const adapter = transactionAdapter(raw.transaction);
                const serialize = inheritedDataFunction(
                    raw.transaction,
                    "serialize"
                );
                if (!serialize) {
                    throw new ProviderRpcError(4200, invalidSolanaTransactionRequest);
                }
                let serialized;
                try {
                    serialized = adapter.type === "legacy"
                        ? applyFunction(serialize, raw.transaction, [{
                            requireAllSignatures: false,
                            verifySignatures: false,
                        }])
                        : applyFunction(serialize, raw.transaction, []);
                } catch {
                    throw new ProviderRpcError(4200, invalidSolanaTransactionRequest);
                }
                transaction = Base58.encode(
                    bytesSnapshot(serialized, invalidSolanaTransactionRequest)
                );
            } else if (typeof raw.transaction !== "undefined") {
                transaction = normalizedBase58Value(
                    raw.transaction,
                    invalidSolanaTransactionRequest
                );
            }
            const normalized = createObjectNormally(null);
            if (transaction) { normalized.transaction = transaction; }
            if (!transaction && typeof raw.message !== "undefined") {
                normalized.message = normalizedBase58Value(
                    raw.message,
                    invalidSolanaTransactionRequest
                );
            }
            if (typeof raw.options !== "undefined") {
                normalized.options = outboundDataSnapshot(raw.options);
            }
            normalizedParams = typeof (transaction || normalized.message) === "string"
                ? trustedOutboundRecord(normalized)
                : outboundDataSnapshot(normalized);
            metadata.messages = [transaction || normalized.message];
            break;
        }
        default:
            throw new ProviderRpcError(
                4200,
                `Big Wallet does not support ${method}`
            );
    }
    return {metadata, params: normalizedParams};
}

function wirePayload(record) {
    const payload = {id: record.wireId, method: record.metadata.method};
    if (typeof record.payload.params !== "undefined") {
        payload.params = record.payload.params;
    }
    return outboundDataSnapshot(payload);
}

function dispatchOperation(provider, record) {
    const state = getProviderState(provider);
    if (!state.runtime.owns(record)) { return false; }
    if (state.transport.isCurrent() !== true) {
        retire(provider, providerReplacementError());
        return false;
    }
    const method = record.metadata.method;
    if (method !== "connect" && !state.publicKey) {
        rejectOperation(
            provider,
            record,
            new ProviderRpcError(4100, providerNotReadyMessage)
        );
        return false;
    }
    if (method === "connect" && state.publicKey &&
        !state.accountRevocationTombstone) {
        const wasConnected = state.isConnected;
        state.isConnected = true;
        const settled = state.runtime.resolve(
            record,
            {publicKey: state.publicKey}
        );
        if (settled && !wasConnected) {
            emitProvider(provider, "connect", state.publicKey);
        }
        return settled;
    }
    if (method === "connect" &&
        record.payload.params?.onlyIfTrusted === true) {
        rejectOperation(
            provider,
            record,
            new ProviderRpcError(4100, providerNotReadyMessage)
        );
        return false;
    }
    const authorization = authorizationSnapshot(state);
    record.metadata.authorization = authorization;
    const message = {
        accountRevision: authorization.accountRevision,
        body: {
            object: wirePayload(record),
            publicKey: authorization.publicKey || "",
        },
        id: record.wireId,
        name: method,
        provider: "solana",
        providerGeneration: state.generation,
        solanaAuthorizationEpoch: authorization.solanaAuthorizationEpoch,
    };
    if (!state.runtime.owns(record)) {
        return false;
    }
    if (state.transport.isCurrent() !== true) {
        retire(provider, providerReplacementError());
        return false;
    }
    let didPost = false;
    try {
        record.metadata.dispatched = true;
        didPost = state.transport.postRequest(message) === true;
    } catch (error) {
        rejectOperation(provider, record, error);
        return false;
    }
    if (!didPost) {
        retire(provider, providerReplacementError());
        return false;
    }
    return true;
}

function registerOperation(provider, method, params, originalId) {
    const state = getProviderState(provider);
    if (state.runtime.phase === "retired") {
        return Promise.reject(providerReplacementError());
    }
    if (state.transport.isCurrent() !== true) {
        retire(provider, providerReplacementError());
        return Promise.reject(providerReplacementError());
    }
    const normalized = normalizeRequest(method, params);
    if (state.runtime.phase === "retired" ||
        state.transport.isCurrent() !== true) {
        retire(provider, providerReplacementError());
        return Promise.reject(providerReplacementError());
    }
    const record = state.runtime.register({
        metadata: normalized.metadata,
        originalId,
        payload: {method, params: normalized.params},
    });
    if (state.runtime.phase === "ready") {
        dispatchOperation(provider, record);
    } else if (!state.runtime.enqueue(record)) {
        rejectOperation(provider, record, providerReplacementError());
    }
    return record.promise;
}

function signedResult(
    provider,
    record,
    encodedSignatures,
    approvalCommitted = false
) {
    const state = getProviderState(provider);
    const metadata = record.metadata;
    if (!operationIsCurrent(provider, record, approvalCommitted)) {
        rejectOperation(provider, record, providerReplacementError());
        return false;
    }
    if (!metadata.messages ||
        metadata.messages.length !== encodedSignatures.length) {
        rejectOperation(
            provider,
            record,
            new ProviderRpcError(4200, mismatchedSolanaTransactionSignatures)
        );
        return false;
    }
    let signatures;
    let signerPublicKey;
    try {
        signatures = [];
        for (let index = 0; index < encodedSignatures.length; index += 1) {
            signatures[index] = signatureBytes(encodedSignatures[index]);
        }
        if (!validPublicKeyString(metadata.authorization?.publicKey)) {
            throw providerReplacementError();
        }
        signerPublicKey = new PublicKey(metadata.authorization.publicKey);
    } catch (error) {
        rejectOperation(provider, record, error);
        return false;
    }
    if (!metadata.adapters) {
        if (metadata.method === "signAllTransactions") {
            const encoded = [];
            for (let index = 0; index < encodedSignatures.length; index += 1) {
                encoded[index] = encodedSignatures[index];
            }
            return state.runtime.resolve(record, {
                publicKey: signerPublicKey,
                signatures: encoded,
            });
        }
        const encoded = encodedSignatures[0];
        return state.runtime.resolve(record, {
            publicKey: signerPublicKey,
            signature: metadata.respondWithBuffer
                ? Utils.messageToBuffer(signatures[0])
                : encoded,
        });
    }
    if (metadata.adapters.length !== signatures.length) {
        rejectOperation(
            provider,
            record,
            new ProviderRpcError(4200, mismatchedSolanaTransactionSignatures)
        );
        return false;
    }
    const writes = [];
    const plans = [];
    const signerTargets = new MapConstructor;
    try {
        for (let index = 0; index < metadata.adapters.length; index += 1) {
            const adapter = metadata.adapters[index];
            if (!transactionMessageMatches(adapter)) {
                throw new ProviderRpcError(
                    4200,
                    mismatchedSolanaTransactionSignatures
                );
            }
            const plan = signerPlan(
                adapter,
                metadata.authorization.publicKey,
                signatures[index]
            );
            let properties = getMapEntry(signerTargets, plan.target);
            if (!properties) {
                properties = new MapConstructor;
                setMapEntry(signerTargets, plan.target, properties);
            }
            if (getMapEntry(properties, plan.property)) {
                throw new ProviderRpcError(4200, solanaSignatureApplicationError);
            }
            setMapEntry(properties, plan.property, true);
            plans[index] = plan;
        }
        for (let index = 0; index < plans.length; index += 1) {
            if (!operationIsCurrent(provider, record, approvalCommitted)) {
                throw providerReplacementError();
            }
            writes[writes.length] = plans[index];
            applySignerPlan(plans[index]);
            if (!operationIsCurrent(provider, record, approvalCommitted)) {
                throw providerReplacementError();
            }
        }
        if (!transactionMessagesMatch(metadata.adapters)) {
            throw new ProviderRpcError(
                4200,
                mismatchedSolanaTransactionSignatures
            );
        }
        if (!operationIsCurrent(provider, record, approvalCommitted)) {
            throw providerReplacementError();
        }
        let result = metadata.adapters[0].transaction;
        if (metadata.method === "signAllTransactions") {
            result = [];
            for (let index = 0; index < metadata.adapters.length; index += 1) {
                result[index] = metadata.adapters[index].transaction;
            }
        }
        const settled = state.runtime.resolve(
            record,
            result
        );
        if (!settled) { throw providerReplacementError(); }
        return true;
    } catch (error) {
        restoreSignatureWrites(writes);
        if (state.runtime.owns(record)) {
            rejectOperation(provider, record, error);
        }
        return false;
    }
}

function normalizedConfiguration(configuration, current) {
    if (!configuration || typeof configuration !== "object") {
        throw new ProviderRpcError(-32603, "Invalid Solana configuration");
    }
    const publicKey = configuration.publicKey == null
        ? null
        : configuration.publicKey;
    const accountRevision = configuration.accountRevision;
    const solanaAuthorizationEpoch = configuration.solanaAuthorizationEpoch;
    if ((publicKey !== null && !validPublicKeyString(publicKey)) ||
        typeof configuration.isConnected !== "boolean" ||
        !Number.isSafeInteger(accountRevision) || accountRevision < 0 ||
        !Number.isSafeInteger(solanaAuthorizationEpoch) ||
        solanaAuthorizationEpoch < 0) {
        throw new ProviderRpcError(-32603, "Invalid Solana configuration");
    }
    if (accountRevision < current.accountRevision ||
        solanaAuthorizationEpoch < current.solanaAuthorizationEpoch) {
        return null;
    }
    return {
        accountRevision,
        isConnected: configuration.isConnected && publicKey !== null,
        publicKey,
        reauthorizationRevision: configuration.reauthorizationRevision,
        solanaAuthorizationEpoch,
    };
}

function applyConfiguration(provider, envelope) {
    const state = getProviderState(provider);
    if (envelope.suppressUpdate === true) {
        return state.runtime.phase === "ready";
    }
    const configuration = normalizedConfiguration(envelope.configuration, state);
    const previousPublicKey = state.publicKey?.toString() || null;
    const previousConnected = state.isConnected;
    const reauthorizationRevision = configuration?.reauthorizationRevision;
    const hasReauthorization = Number.isSafeInteger(reauthorizationRevision) &&
        reauthorizationRevision >= 0;
    const switchAccount = hasReauthorization
        ? reauthorizationRevision > state.reauthorizationRevision
        : envelope.switchAccount === true;
    if (hasReauthorization) {
        state.reauthorizationRevision = Math.max(
            state.reauthorizationRevision,
            reauthorizationRevision
        );
    }
    const preservesTombstone = state.accountRevocationTombstone &&
        !switchAccount;
    if (configuration && !preservesTombstone) {
        const canClearTombstone = state.accountRevocationTombstone &&
            switchAccount &&
            configuration.publicKey !== null;
        state.accountRevision = configuration.accountRevision;
        state.solanaAuthorizationEpoch = configuration.solanaAuthorizationEpoch;
        if (!state.accountRevocationTombstone || canClearTombstone) {
            state.accountRevocationTombstone = false;
            state.publicKey = configuration.publicKey
                ? new PublicKey(configuration.publicKey)
                : null;
            state.isConnected = configuration.isConnected;
        } else {
            state.publicKey = null;
            state.isConnected = false;
        }
    }
    if (state.runtime.phase === "failed") {
        state.runtime.drain(record => dispatchOperation(provider, record));
    }
    const configuredConnected = state.isConnected;
    const nextPublicKey = state.publicKey?.toString() || null;
    if (previousPublicKey !== nextPublicKey) {
        clearMap(state.standardAccountsByAddress);
        emitProvider(provider, "accountChanged", state.publicKey);
        emitStandardChange(provider, {accounts: provider.standardAccounts()});
    }
    if (!previousConnected && configuredConnected && state.publicKey) {
        emitProvider(provider, "connect", state.publicKey);
    } else if (previousConnected && !configuredConnected) {
        emitProvider(provider, "disconnect");
    }
    state.runtime.drain(record => dispatchOperation(provider, record));
    return true;
}

function resultValue(envelope) {
    return envelope?.result && typeof envelope.result === "object" &&
        typeof envelope.result.signature === "string"
        ? envelope.result.signature
        : envelope.result;
}

function applyEnvelope(provider, envelope) {
    const state = providerState(provider);
    if (!state || state.runtime.phase === "retired") {
        return false;
    }
    if (state.transport.isCurrent() !== true) {
        retire(provider, providerReplacementError());
        return false;
    }
    try {
        envelope = outboundDataSnapshot(envelope);
    } catch {
        return false;
    }
    if (!envelope || typeof envelope !== "object") { return false; }
    if (envelope.kind === "configuration") {
        return applyConfiguration(provider, envelope);
    }
    if (envelope.kind === "configurationError") {
        const error = normalizeSolanaProviderError(envelope.error);
        if (!state.runtime.failLoading(error)) { return false; }
        const wasConnected = state.isConnected;
        state.isConnected = false;
        if (wasConnected) { emitProvider(provider, "disconnect"); }
        return true;
    }
    if (!Number.isSafeInteger(envelope.id)) { return false; }
    const record = state.runtime.operation(envelope.id);
    if (!record || !state.runtime.owns(record) ||
        record.metadata.dispatched !== true) {
        return false;
    }
    const expectedName = record.metadata.method === "disconnect"
        ? ["disconnect", "revokePermissions"]
        : [record.metadata.method];
    if (envelope.name !== expectedName[0] &&
        envelope.name !== expectedName[1]) {
        return state.runtime.reject(
            record,
            new ProviderRpcError(-32603, malformedSolanaResponse)
        );
    }
    if (envelope.kind === "error") {
        if (envelope.suppressUpdate !== true && envelope.authorizationFailure &&
            authorizationMatches(state, record.metadata.authorization)) {
            let synchronized = false;
            try {
                advanceEpoch(state);
                synchronized = state.transport.synchronizeSolanaEpoch(
                    state.solanaAuthorizationEpoch
                ) !== false && state.transport.isCurrent() === true;
            } catch {
            }
            if (!synchronized) {
                retire(provider, providerReplacementError());
                return false;
            }
            clearAuthorization(provider, true);
        }
        return state.runtime.reject(
            record,
            normalizeSolanaProviderError(
                envelope.error,
                envelope.error?.code,
                envelope.error?.data
            )
        );
    }
    if (record.metadata.method === "disconnect") {
        if (envelope.kind !== "result") {
            return state.runtime.reject(
                record,
                new ProviderRpcError(-32603, malformedSolanaResponse)
            );
        }
        if (authorizationMatches(state, record.metadata.authorization)) {
            let synchronized = false;
            try {
                advanceEpoch(state);
                synchronized = state.transport.synchronizeSolanaEpoch(
                    state.solanaAuthorizationEpoch
                ) !== false && state.transport.isCurrent() === true;
            } catch {
            }
            if (!synchronized) {
                retire(provider, providerReplacementError());
                return false;
            }
            clearAuthorization(provider, true);
        }
        return state.runtime.resolve(record, true);
    }
    if (envelope.kind === "batchResult") {
        if (record.metadata.method !== "signAllTransactions" ||
            !isArrayNormally(envelope.results) ||
            envelope.results.length === 0 ||
            envelope.results.length > maximumTransactionBatchSize) {
            rejectOperation(
                provider,
                record,
                new ProviderRpcError(4200, invalidSolanaSignatureResponse)
            );
            return false;
        }
        return signedResult(
            provider,
            record,
            envelope.results,
            envelope.approvalCommitted === true
        );
    }
    if (envelope.kind !== "result") {
        return state.runtime.reject(
            record,
            new ProviderRpcError(-32603, malformedSolanaResponse)
        );
    }
    if (record.metadata.method === "connect") {
        const publicKeyValue = envelope.result?.publicKey || envelope.result;
        if (!validPublicKeyString(publicKeyValue)) {
            return state.runtime.reject(
                record,
                new ProviderRpcError(4100, providerNotReadyMessage)
            );
        }
        const resultPublicKey = new PublicKey(publicKeyValue);
        if (envelope.configurationApplied === false) {
            if (envelope.approvalCommitted === true) {
                return state.runtime.resolve(record, {
                    publicKey: resultPublicKey,
                });
            }
            return rejectOperation(
                provider,
                record,
                providerReplacementError()
            );
        }
        const previousPublicKey = state.publicKey?.toString() || null;
        const appliedConfigurationMatches =
            envelope.configurationApplied === true &&
            state.accountRevocationTombstone !== true &&
            state.isConnected === true &&
            previousPublicKey === publicKeyValue;
        if (appliedConfigurationMatches) {
            return state.runtime.resolve(record, {
                publicKey: state.publicKey,
            });
        }
        if (!authorizationMatches(state, record.metadata.authorization)) {
            if (envelope.approvalCommitted === true) {
                return state.runtime.resolve(record, {
                    publicKey: resultPublicKey,
                });
            }
            return rejectOperation(
                provider,
                record,
                providerReplacementError()
            );
        }
        const wasConnected = state.isConnected;
        state.accountRevocationTombstone = false;
        if (previousPublicKey !== publicKeyValue) {
            try {
                incrementRevision(state);
            } catch (error) {
                clearAuthorization(provider, true);
                state.runtime.reject(record, error);
                return false;
            }
            clearMap(state.standardAccountsByAddress);
        }
        state.publicKey = resultPublicKey;
        state.isConnected = true;
        const settled = state.runtime.resolve(
            record,
            {publicKey: state.publicKey}
        );
        if (settled && !wasConnected) {
            emitProvider(provider, "connect", state.publicKey);
        }
        if (previousPublicKey !== publicKeyValue) {
            emitProvider(provider, "accountChanged", state.publicKey);
            emitStandardChange(provider, {accounts: provider.standardAccounts()});
        }
        return settled;
    }
    const value = resultValue(envelope);
    if (record.metadata.method === "signMessage" ||
        record.metadata.method === "signTransaction" ||
        record.metadata.method === "signAndSendTransaction") {
        if (typeof value !== "string") {
            rejectOperation(
                provider,
                record,
                new ProviderRpcError(4200, invalidSolanaSignatureResponse)
            );
            return false;
        }
        return signedResult(
            provider,
            record,
            [value],
            envelope.approvalCommitted === true
        );
    }
    return state.runtime.resolve(record, envelope.result);
}

function retire(provider, error = providerReplacementError()) {
    const state = providerState(provider);
    if (!state || state.runtime.phase === "retired") { return 0; }
    const count = state.runtime.retire(error);
    state.activeDisconnect = null;
    clearAuthorization(provider, true);
    clearSet(state.standardChangeListeners);
    return count;
}

function snapshot(provider) {
    const state = providerState(provider);
    if (!state) { return null; }
    const publicKey = state.publicKey?.toString() || null;
    if ((publicKey !== null && !validPublicKeyString(publicKey)) ||
        !Number.isSafeInteger(state.accountRevision) ||
        state.accountRevision < 0 ||
        !Number.isSafeInteger(state.solanaAuthorizationEpoch) ||
        state.solanaAuthorizationEpoch < 0) {
        return null;
    }
    return freezeObjectNormally({
        accountRevocationTombstone:
            state.accountRevocationTombstone === true,
        accountRevision: state.accountRevision,
        isConnected: state.isConnected === true && publicKey !== null,
        publicKey,
        reauthorizationRevision: state.reauthorizationRevision,
        solanaAuthorizationEpoch: state.solanaAuthorizationEpoch,
    });
}

function isReady(provider) {
    return providerState(provider)?.runtime.phase === "ready";
}

function initialAuthorization(initialState) {
    let initial = {};
    if (initialState && typeof initialState === "object") {
        try {
            initial = outboundDataSnapshot(initialState);
        } catch {
        }
    }
    const accountRevision = Number.isSafeInteger(initial.accountRevision) &&
        initial.accountRevision >= 0
        ? initial.accountRevision
        : 0;
    const solanaAuthorizationEpoch = Number.isSafeInteger(
        initial.solanaAuthorizationEpoch
    ) && initial.solanaAuthorizationEpoch >= 0
        ? initial.solanaAuthorizationEpoch
        : 0;
    const tombstone = initial.accountRevocationTombstone === true;
    const publicKey = !tombstone && validPublicKeyString(initial.publicKey)
        ? new PublicKey(initial.publicKey)
        : null;
    return {
        accountRevision,
        accountRevocationTombstone: tombstone,
        isConnected: !!publicKey && initial.isConnected === true,
        publicKey,
        reauthorizationRevision:
            Number.isSafeInteger(initial.reauthorizationRevision) &&
            initial.reauthorizationRevision >= 0
                ? initial.reauthorizationRevision
                : 0,
        solanaAuthorizationEpoch,
    };
}

class BigWalletSolana extends EventEmitter {

    constructor(providerGeneration, transport, initialState = null) {
        super();
        if (typeof providerGeneration !== "string" ||
            providerGeneration.length === 0) {
            throw new TypeError("Invalid Solana provider generation");
        }
        const authorization = initialAuthorization(initialState);
        setProviderState(this, {
            activeDisconnect: null,
            generation: providerGeneration,
            runtime: new OperationRuntime(providerGeneration, {
                firstWireId: 2,
                wireIdStep: 2,
            }),
            standardAccountsByAddress: new MapConstructor,
            standardChangeListeners: new SetConstructor,
            standardFeatures: null,
            transport: capturedTransport(transport),
            ...authorization,
        });
        definePropertyNormally(this, "isPhantom", {
            configurable: true,
            enumerable: true,
            value: true,
            writable: true,
        });
        definePropertyNormally(this, "isBigWallet", {
            configurable: true,
            enumerable: true,
            value: true,
            writable: true,
        });
        this.connect = this.connect.bind(this);
        this.disconnect = this.disconnect.bind(this);
        this.request = this.request.bind(this);
        this.signMessage = this.signMessage.bind(this);
        this.signTransaction = this.signTransaction.bind(this);
        this.signAllTransactions = this.signAllTransactions.bind(this);
        this.signAndSendTransaction = this.signAndSendTransaction.bind(this);
        this.standardConnect = this.standardConnect.bind(this);
        this.standardDisconnect = this.standardDisconnect.bind(this);
        this.standardOn = this.standardOn.bind(this);
        this.standardSignMessage = this.standardSignMessage.bind(this);
        this.standardSignTransaction = this.standardSignTransaction.bind(this);
        this.standardSignAndSendTransaction =
            this.standardSignAndSendTransaction.bind(this);
    }

    get providerGeneration() {
        return getProviderState(this).generation;
    }

    get publicKey() {
        return getProviderState(this).publicKey;
    }

    set publicKey(_) {}

    get isConnected() {
        return getProviderState(this).isConnected;
    }

    set isConnected(_) {}

    get didGetLatestConfiguration() {
        return isReady(this);
    }

    set didGetLatestConfiguration(_) {}

    get accountRevision() {
        return getProviderState(this).accountRevision;
    }

    get accountRevocationTombstone() {
        return getProviderState(this).accountRevocationTombstone;
    }

    get solanaAuthorizationEpoch() {
        return getProviderState(this).solanaAuthorizationEpoch;
    }

    get retired() {
        return getProviderState(this).runtime.phase === "retired";
    }

    set retired(value) {
        if (value === true) { retire(this); }
    }

    connect(params) {
        return this.request({method: "connect", params});
    }

    request(payload) {
        try {
            const shell = outboundDataSnapshot({
                id: payload?.id,
                method: payload?.method,
            });
            if (shell.method === "disconnect") {
                return this.disconnect();
            }
            return registerOperation(
                this,
                shell.method,
                payload?.params,
                shell.id
            );
        } catch (error) {
            return Promise.reject(error);
        }
    }

    disconnect() {
        const state = getProviderState(this);
        if (state.runtime.phase === "retired") {
            return Promise.resolve(true);
        }
        if (state.activeDisconnect &&
            state.runtime.owns(state.activeDisconnect) &&
            authorizationMatches(
                state,
                state.activeDisconnect.metadata.authorization
            )) {
            return state.activeDisconnect.promise;
        }
        if (state.solanaAuthorizationEpoch === maximumCounter) {
            const error = providerReplacementError();
            retire(this, error);
            return Promise.reject(error);
        }
        const metadata = createMetadata("disconnect");
        let record;
        try {
            record = state.runtime.register({
                metadata,
                payload: {method: "disconnect"},
            });
        } catch (error) {
            return Promise.reject(error);
        }
        state.activeDisconnect = record;
        record.promise.then(
            () => {
                if (state.activeDisconnect === record) {
                    state.activeDisconnect = null;
                }
            },
            () => {
                if (state.activeDisconnect === record) {
                    state.activeDisconnect = null;
                }
            }
        );
        metadata.authorization = authorizationSnapshot(state);
        let posted = false;
        try {
            metadata.dispatched = true;
            posted = state.transport.postDisconnect({
                id: record.wireId,
                provider: "solana",
                providerGeneration: state.generation,
                solanaAuthorizationEpoch: state.solanaAuthorizationEpoch,
            }) === true;
        } catch (error) {
            state.runtime.reject(record, error);
            return record.promise;
        }
        if (!posted) {
            state.runtime.reject(record, providerReplacementError());
        }
        return record.promise;
    }

    externalDisconnect() {
        const state = getProviderState(this);
        if (state.runtime.phase === "retired") { return Promise.resolve(true); }
        let synchronized = false;
        try {
            advanceEpoch(state);
            synchronized = state.transport.synchronizeSolanaEpoch(
                state.solanaAuthorizationEpoch
            ) !== false && state.transport.isCurrent() === true;
        } catch {
        }
        if (!synchronized) {
            retire(this, providerReplacementError());
            return Promise.resolve(true);
        }
        clearAuthorization(this, true);
        return Promise.resolve(true);
    }

    retire(error) {
        return retire(this, error);
    }

    signMessage(message, display) {
        const params = {message};
        if (typeof display !== "undefined") { params.display = display; }
        return this.request({method: "signMessage", params});
    }

    signTransactionPayload(message) {
        return {method: "signTransaction", params: {message}};
    }

    signTransaction(transaction) {
        return this.request({
            method: "signTransaction",
            params: {transaction},
        });
    }

    signAllTransactions(transactions) {
        return this.request({
            method: "signAllTransactions",
            params: {transactions},
        });
    }

    signAndSendTransaction(transaction, options) {
        const params = {transaction};
        if (typeof options !== "undefined") { params.options = options; }
        return this.request({method: "signAndSendTransaction", params});
    }

    standardOn(event, listener) {
        const state = getProviderState(this);
        if (state.runtime.phase === "retired" ||
            event !== standardChangeEvent || typeof listener !== "function") {
            return () => {};
        }
        addSetEntry(state.standardChangeListeners, listener);
        return () => deleteSetEntry(state.standardChangeListeners, listener);
    }

    standardAccounts() {
        const state = getProviderState(this);
        if (!state.publicKey) { return []; }
        const address = state.publicKey.toString();
        let account = getMapEntry(state.standardAccountsByAddress, address);
        if (!account) {
            const publicKeyBytes = new Uint8Array(state.publicKey.toBytes());
            account = freezeObjectNormally({
                address,
                get publicKey() {
                    return publicKeyBytes.slice();
                },
                chains: solanaChains,
                features: solanaAccountFeatures,
                label: walletName,
            });
            setMapEntry(state.standardAccountsByAddress, address, account);
        }
        return [account];
    }

    standardFeatures() {
        const state = getProviderState(this);
        if (state.standardFeatures) { return state.standardFeatures; }
        state.standardFeatures = freezeObjectNormally({
            [standardConnect]: freezeObjectNormally({
                version: walletStandardVersion,
                connect: this.standardConnect,
            }),
            [standardDisconnect]: freezeObjectNormally({
                version: walletStandardVersion,
                disconnect: this.standardDisconnect,
            }),
            [standardEvents]: freezeObjectNormally({
                version: walletStandardVersion,
                on: this.standardOn,
            }),
            [solanaSignAndSendTransaction]: freezeObjectNormally({
                version: walletStandardVersion,
                supportedTransactionVersions: solanaSupportedTransactionVersions,
                signAndSendTransaction: this.standardSignAndSendTransaction,
            }),
            [solanaSignTransaction]: freezeObjectNormally({
                version: walletStandardVersion,
                supportedTransactionVersions: solanaSupportedTransactionVersions,
                signTransaction: this.standardSignTransaction,
            }),
            [solanaSignMessage]: freezeObjectNormally({
                version: solanaSignMessageFeatureVersion,
                signMessage: this.standardSignMessage,
            }),
        });
        return state.standardFeatures;
    }

    async standardConnect(input) {
        if (input?.silent === true && isReady(this) && !this.publicKey) {
            return {accounts: []};
        }
        try {
            await this.connect(input?.silent === true
                ? {onlyIfTrusted: true}
                : undefined);
        } catch (error) {
            if (input?.silent === true && error?.code === 4100) {
                return {accounts: []};
            }
            throw error;
        }
        return {accounts: this.standardAccounts()};
    }

    async standardDisconnect() {
        await this.disconnect();
    }

    assertStandardAccount(account) {
        const publicKey = this.publicKey;
        if (!publicKey || !account || account.address !== publicKey.toString()) {
            throw new ProviderRpcError(4100, providerNotReadyMessage);
        }
    }

    assertSupportedStandardChain(chain, isRequired) {
        if ((!isRequired && typeof chain === "undefined") ||
            (chain === solanaMainnetChain || chain === solanaDevnetChain ||
                chain === solanaTestnetChain)) {
            return;
        }
        throw new ProviderRpcError(4200, unsupportedSolanaChain);
    }

    standardBytesSnapshot(value, message) {
        return bytesSnapshot(value, message);
    }

    standardSignatureBytes(value) {
        const signature = bytesSnapshot(value, invalidSolanaSignatureResponse);
        if (signature.length !== 64) {
            throw new ProviderRpcError(4200, invalidSolanaSignatureResponse);
        }
        return signature;
    }

    standardBase58Signature(value) {
        return this.standardSignatureBytes(signatureBytes(value));
    }

    standardSignAndSendOptions(input) {
        const options = outboundDataSnapshot(input?.options || {});
        if (typeof options.mode !== "undefined" && options.mode !== "serial") {
            throw new ProviderRpcError(4200, invalidSolanaTransactionOptions);
        }
        if (input?.chain) { options.bigWalletCluster = input.chain; }
        return options;
    }

    decodeShortVec(bytes, offset) {
        let value = 0;
        let shift = 0;
        let cursor = offset;
        while (cursor < bytes.length) {
            const element = bytes[cursor];
            cursor += 1;
            if (shift >= 32) {
                throw new ProviderRpcError(4200, invalidSolanaTransactionRequest);
            }
            value += (element & 0x7f) * Math.pow(2, shift);
            if ((element & 0x80) === 0) {
                return {value, offset: cursor};
            }
            shift += 7;
        }
        throw new ProviderRpcError(4200, invalidSolanaTransactionRequest);
    }

    signerDetailsForMessage(messageBytes, publicKeyBytes) {
        if (messageBytes.length === 0) {
            throw new ProviderRpcError(4200, invalidSolanaTransactionRequest);
        }
        const firstByte = messageBytes[0];
        let requiredSignaturesCount;
        let accountCountOffset;
        if ((firstByte & 0x80) === 0) {
            requiredSignaturesCount = firstByte;
            accountCountOffset = 3;
        } else {
            const version = firstByte & 0x7f;
            if (version !== 0 || messageBytes.length < 4) {
                throw new ProviderRpcError(4200, invalidSolanaTransactionRequest);
            }
            requiredSignaturesCount = messageBytes[1];
            accountCountOffset = 4;
        }
        const accountCount = this.decodeShortVec(
            messageBytes,
            accountCountOffset
        );
        if (accountCount.value < requiredSignaturesCount) {
            throw new ProviderRpcError(4200, invalidSolanaTransactionRequest);
        }
        const accountKeysStart = accountCount.offset;
        if (accountKeysStart + accountCount.value * 32 > messageBytes.length) {
            throw new ProviderRpcError(4200, invalidSolanaTransactionRequest);
        }
        for (let index = 0; index < requiredSignaturesCount; index += 1) {
            const keyOffset = accountKeysStart + index * 32;
            let matches = true;
            for (let byteIndex = 0; byteIndex < 32; byteIndex += 1) {
                if (messageBytes[keyOffset + byteIndex] !==
                    publicKeyBytes[byteIndex]) {
                    matches = false;
                    break;
                }
            }
            if (matches) {
                return {requiredSignaturesCount, signerIndex: index};
            }
        }
        throw new ProviderRpcError(4200, invalidSolanaTransactionRequest);
    }

    preparedStandardTransaction(transaction) {
        const transactionBytes = bytesSnapshot(
            transaction,
            invalidSolanaTransactionRequest
        );
        const signatureCount = this.decodeShortVec(transactionBytes, 0);
        if (signatureCount.value <= 0) {
            throw new ProviderRpcError(4200, invalidSolanaTransactionRequest);
        }
        const signaturesStart = signatureCount.offset;
        const messageStart = signaturesStart + signatureCount.value * 64;
        if (messageStart >= transactionBytes.length || !this.publicKey) {
            throw new ProviderRpcError(4200, invalidSolanaTransactionRequest);
        }
        const messageBytes = transactionBytes.slice(messageStart);
        const signer = this.signerDetailsForMessage(
            messageBytes,
            new Uint8Array(this.publicKey.toBytes())
        );
        if (signatureCount.value !== signer.requiredSignaturesCount ||
            signer.signerIndex >= signatureCount.value) {
            throw new ProviderRpcError(4200, invalidSolanaTransactionRequest);
        }
        return {
            messageBytes,
            signatureOffset: signaturesStart + signer.signerIndex * 64,
            transactionBytes,
        };
    }

    async standardSignMessage(...inputs) {
        if (inputs.length > maximumTransactionBatchSize) {
            throw new ProviderRpcError(4200, invalidSolanaMessageRequest);
        }
        const authorization = authorizationSnapshot(getProviderState(this));
        const prepared = [];
        for (let index = 0; index < inputs.length; index += 1) {
            const input = inputs[index];
            this.assertStandardAccount(input?.account);
            prepared[index] = bytesSnapshot(
                input?.message,
                invalidSolanaMessageRequest
            );
        }
        const outputs = [];
        for (let index = 0; index < prepared.length; index += 1) {
            const message = prepared[index];
            requireAuthorization(this, authorization);
            const response = await this.signMessage(message);
            outputs[index] = {
                signedMessage: message,
                signature: this.standardSignatureBytes(response.signature),
            };
        }
        return outputs;
    }

    async standardSignTransaction(...inputs) {
        if (inputs.length > maximumTransactionBatchSize) {
            throw new ProviderRpcError(4200, invalidSolanaTransactionBatchRequest);
        }
        const authorization = authorizationSnapshot(getProviderState(this));
        const prepared = [];
        for (let index = 0; index < inputs.length; index += 1) {
            const input = inputs[index];
            this.assertStandardAccount(input?.account);
            this.assertSupportedStandardChain(input?.chain, false);
            prepared[index] = this.preparedStandardTransaction(
                input?.transaction
            );
        }
        const outputs = [];
        for (let index = 0; index < prepared.length; index += 1) {
            const transaction = prepared[index];
            requireAuthorization(this, authorization);
            const response = await this.request(
                this.signTransactionPayload(Base58.encode(transaction.messageBytes))
            );
            const signature = this.standardBase58Signature(response.signature);
            const signedTransaction = new Uint8Array(
                transaction.transactionBytes
            );
            signedTransaction.set(signature, transaction.signatureOffset);
            outputs[index] = {signedTransaction};
        }
        return outputs;
    }

    async standardSignAndSendTransaction(...inputs) {
        if (inputs.length > maximumTransactionBatchSize) {
            throw new ProviderRpcError(4200, invalidSolanaTransactionBatchRequest);
        }
        const authorization = authorizationSnapshot(getProviderState(this));
        const prepared = [];
        for (let index = 0; index < inputs.length; index += 1) {
            const input = inputs[index];
            this.assertStandardAccount(input?.account);
            this.assertSupportedStandardChain(input?.chain, true);
            prepared[index] = {
                options: this.standardSignAndSendOptions(input),
                transaction: bytesSnapshot(
                    input?.transaction,
                    invalidSolanaTransactionRequest
                ),
            };
        }
        const outputs = [];
        for (let index = 0; index < prepared.length; index += 1) {
            requireAuthorization(this, authorization);
            const response = await this.signAndSendTransaction(
                prepared[index].transaction,
                prepared[index].options
            );
            outputs[index] = {
                signature: this.standardBase58Signature(response.signature),
            };
        }
        return outputs;
    }
}

BigWalletSolana.applyEnvelope = applyEnvelope;
BigWalletSolana.retire = retire;
BigWalletSolana.snapshot = snapshot;
BigWalletSolana.isReady = isReady;

export { applyEnvelope, isReady, retire, snapshot };
export default BigWalletSolana;
