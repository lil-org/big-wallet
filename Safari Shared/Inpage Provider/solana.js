// ∅ 2026 lil org

"use strict";

import Utils from "./utils";
import IdMapping from "./id_mapping";
import Base58 from "./base58";
import ProviderRpcError from "./error";
import { EventEmitter } from "events";

class PublicKey {

    constructor(value) {
        this.stringValue = value;
    }

    equals(publicKey) {
        return this.stringValue === publicKey.toString();
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

class BigWalletSolana extends EventEmitter {

    constructor() {
        super();

        this.idMapping = new IdMapping();
        this.callbacks = new Map();
        this.pendingRequests = new Map();

        this.isPhantom = true;
        this.publicKey = null;
        this.isConnected = false;
        this.isBigWallet = true;

        this.didGetLatestConfiguration = false;
        this.pendingPayloads = [];

        this.connect = this.connect.bind(this);
        this.disconnect = this.disconnect.bind(this);
        this.request = this.request.bind(this);
        this.signMessage = this.signMessage.bind(this);
        this.signTransaction = this.signTransaction.bind(this);
        this.signAllTransactions = this.signAllTransactions.bind(this);
        this.signAndSendTransaction = this.signAndSendTransaction.bind(this);
    }

    connect(params) {
        const payload = { method: "connect" };
        if (typeof params !== "undefined") {
            payload.params = params;
        }
        return this.request(payload);
    }

    disconnect() {
        window.bigwallet.disconnect("solana");
        return this.performDisconnect();
    }

    externalDisconnect() {
        return this.performDisconnect();
    }

    performDisconnect() {
        const didChangeAccount = this.publicKey !== null;
        this.isConnected = false;
        this.publicKey = null;
        if (didChangeAccount) {
            this.emit("accountChanged", null);
        }
        this.emit("disconnect");
        return Promise.resolve(true);
    }

    bytesFor(value) {
        if (value instanceof Uint8Array) {
            return value;
        }

        if (typeof ArrayBuffer !== "undefined") {
            if (value instanceof ArrayBuffer) {
                return new Uint8Array(value);
            }

            if (ArrayBuffer.isView(value)) {
                return new Uint8Array(value.buffer, value.byteOffset, value.byteLength);
            }
        }

        return null;
    }

    normalizedBase58Value(value, errorMessage) {
        if (typeof value === "string") {
            return value;
        }

        const bytes = this.bytesFor(value);
        if (bytes) {
            return Base58.encode(bytes);
        }

        throw new ProviderRpcError(4200, errorMessage);
    }

    normalizedBase58Messages(values, errorMessage) {
        return values.map((value) => {
            return this.normalizedBase58Value(value, errorMessage);
        });
    }

    signAllTransactionsMessageParamName(normalizedParams) {
        const hasParam = (name) => Object.prototype.hasOwnProperty.call(normalizedParams, name);
        const hasMessages = hasParam("messages");
        const hasMessage = hasParam("message") && normalizedParams.message != null;

        if (hasMessages && hasMessage) {
            throw new ProviderRpcError(4200, "Big Wallet received ambiguous Solana transaction params");
        }

        if (hasMessages) {
            return "messages";
        }

        if (hasMessage) {
            return "message";
        }

        return null;
    }

    normalizedHexMessage(value, errorMessage) {
        if (typeof value !== "string") {
            throw new ProviderRpcError(4200, errorMessage);
        }

        const rawValue = value.startsWith("0x") ? value.slice(2) : value;
        if (rawValue.length % 2 !== 0 || !/^[0-9a-fA-F]*$/.test(rawValue)) {
            throw new ProviderRpcError(4200, errorMessage);
        }

        return `0x${rawValue}`;
    }

    preparedSignMessageParams(params) {
        const normalizedParams = { ...(params || {}) };
        const errorMessage = "Big Wallet could not normalize this Solana message request";

        if (!("message" in normalizedParams)) {
            throw new ProviderRpcError(4200, errorMessage);
        }

        const signsUtf8Message = typeof normalizedParams.message === "string" &&
            typeof normalizedParams.display === "string" &&
            normalizedParams.display.toLowerCase() === "utf8";

        if (signsUtf8Message) {
            normalizedParams.messageEncoding = "utf8";
            return normalizedParams;
        }

        if (typeof normalizedParams.message === "string") {
            normalizedParams.message = this.normalizedHexMessage(normalizedParams.message, errorMessage);
        } else {
            try {
                normalizedParams.message = Utils.bufferToHex(normalizedParams.message);
            } catch (error) {
                throw new ProviderRpcError(4200, errorMessage);
            }
        }

        normalizedParams.messageEncoding = "hex";
        return normalizedParams;
    }

    normalizeDerivedMessage(normalizedParams, derivedMessage, errorMessage) {
        if ("message" in normalizedParams) {
            const normalizedMessage = this.normalizedBase58Value(normalizedParams.message, errorMessage);
            if (normalizedMessage !== derivedMessage) {
                throw new ProviderRpcError(4200, "Big Wallet received mismatched Solana transaction params");
            }
            normalizedParams.message = normalizedMessage;
        } else {
            normalizedParams.message = derivedMessage;
        }
    }

    canSerializeTransactionMessage(value) {
        return !!value && (typeof value.serializeMessage === "function" ||
            (value.message && typeof value.message.serialize === "function"));
    }

    canSerializeTransaction(value) {
        return !!value && typeof value.serialize === "function";
    }

    canApplyTransactionSignature(value) {
        return !!value && (typeof value.addSignature === "function" ||
            this.canSetVersionedTransactionSignature(value));
    }

    canSetVersionedTransactionSignature(value) {
        return !!value &&
            Array.isArray(value.signatures) &&
            this.versionedTransactionSignerPublicKeys(value) !== null &&
            typeof value.message.header.numRequiredSignatures === "number";
    }

    versionedTransactionSignerPublicKeys(transaction) {
        if (!transaction ||
            !transaction.message ||
            !transaction.message.header ||
            !Array.isArray(transaction.message.staticAccountKeys)) {
            return null;
        }

        return transaction.message.staticAccountKeys.slice(0,
                                                          transaction.message.header.numRequiredSignatures);
    }

    isMatchingPublicKey(publicKey, value) {
        return !!publicKey && !!value && typeof value.toString === "function" && publicKey.equals(value);
    }

    isTransactionObject(value) {
        return this.canSerializeTransactionMessage(value) ||
            this.canSerializeTransaction(value) ||
            this.canApplyTransactionSignature(value);
    }

    assertCanSignTransactionObject(value, errorMessage) {
        if (!this.canSerializeTransactionMessage(value) || !this.canApplyTransactionSignature(value)) {
            throw new ProviderRpcError(4200, errorMessage);
        }
    }

    preparedSignTransactionParams(params) {
        const normalizedParams = { ...(params || {}) };
        let pendingRequestMetadata = null;

        if ("transaction" in normalizedParams && this.isTransactionObject(normalizedParams.transaction)) {
            const transaction = normalizedParams.transaction;
            this.assertCanSignTransactionObject(transaction, "Big Wallet could not normalize this Solana transaction request");
            const derivedMessage = this.encodedMessageFor(transaction);
            this.normalizeDerivedMessage(normalizedParams,
                                         derivedMessage,
                                         "Big Wallet could not normalize this Solana transaction request");
            pendingRequestMetadata = { transactions: [transaction] };
            delete normalizedParams.transaction;
        } else if ("message" in normalizedParams) {
            normalizedParams.message = this.normalizedBase58Value(normalizedParams.message, "Big Wallet could not normalize this Solana transaction request");
        } else {
            throw new ProviderRpcError(4200, "Big Wallet could not normalize this Solana transaction request");
        }

        return {
            params: normalizedParams,
            pendingRequestMetadata: pendingRequestMetadata,
        };
    }

    preparedSignAllTransactionsParams(params) {
        const normalizedParams = { ...(params || {}) };
        let pendingRequestMetadata = null;
        const suppliedMessageParamName = this.signAllTransactionsMessageParamName(normalizedParams);
        const suppliedMessages = suppliedMessageParamName ? normalizedParams[suppliedMessageParamName] : null;

        if (Array.isArray(normalizedParams.transactions)) {
            const transactions = normalizedParams.transactions;
            transactions.forEach((transaction) => {
                this.assertCanSignTransactionObject(transaction, "Big Wallet could not normalize this Solana transaction batch");
            });
            const derivedMessages = transactions.map((transaction) => {
                return this.encodedMessageFor(transaction);
            });

            if (suppliedMessageParamName) {
                if (!Array.isArray(suppliedMessages) || suppliedMessages.length !== derivedMessages.length) {
                    throw new ProviderRpcError(4200, "Big Wallet received mismatched Solana transaction params");
                }

                const normalizedMessages = this.normalizedBase58Messages(suppliedMessages,
                                                                        "Big Wallet could not normalize this Solana transaction batch");
                for (let index = 0; index < normalizedMessages.length; index++) {
                    if (normalizedMessages[index] !== derivedMessages[index]) {
                        throw new ProviderRpcError(4200, "Big Wallet received mismatched Solana transaction params");
                    }
                }
                normalizedParams.messages = normalizedMessages;
            } else {
                normalizedParams.messages = derivedMessages;
            }

            pendingRequestMetadata = { transactions: transactions };
            delete normalizedParams.transactions;
            delete normalizedParams.message;
        } else if (suppliedMessageParamName && Array.isArray(suppliedMessages)) {
            normalizedParams.messages = this.normalizedBase58Messages(suppliedMessages,
                                                                      "Big Wallet could not normalize this Solana transaction batch");
            delete normalizedParams.message;
        } else {
            throw new ProviderRpcError(4200, "Big Wallet could not normalize this Solana transaction batch");
        }

        return {
            params: normalizedParams,
            pendingRequestMetadata: pendingRequestMetadata,
        };
    }

    preparedSignAndSendTransactionParams(params) {
        const normalizedParams = { ...(params || {}) };
        const errorMessage = "Big Wallet could not normalize this Solana transaction request";

        if ("transaction" in normalizedParams && this.isTransactionObject(normalizedParams.transaction)) {
            const transaction = normalizedParams.transaction;
            const encodedTransaction = this.encodedTransactionFor(transaction);
            if (encodedTransaction !== null) {
                if ("message" in normalizedParams && this.canSerializeTransactionMessage(transaction)) {
                    this.normalizeDerivedMessage(normalizedParams,
                                                 this.encodedMessageFor(transaction),
                                                 errorMessage);
                }
                normalizedParams.transaction = encodedTransaction;
            } else if (this.canSerializeTransactionMessage(transaction)) {
                this.normalizeDerivedMessage(normalizedParams,
                                             this.encodedMessageFor(transaction),
                                             errorMessage);
                delete normalizedParams.transaction;
            } else {
                throw new ProviderRpcError(4200, errorMessage);
            }
        } else if ("transaction" in normalizedParams) {
            normalizedParams.transaction = this.normalizedBase58Value(normalizedParams.transaction, errorMessage);
        } else if ("message" in normalizedParams) {
            normalizedParams.message = this.normalizedBase58Value(normalizedParams.message, errorMessage);
        } else {
            throw new ProviderRpcError(4200, errorMessage);
        }

        return {
            params: normalizedParams,
            pendingRequestMetadata: {},
        };
    }

    encodedMessageFor(transaction) {
        return Base58.encode(this.serializedMessageFor(transaction));
    }

    encodedTransactionFor(transaction) {
        const serializedTransaction = this.serializedTransactionFor(transaction);
        if (serializedTransaction === null) {
            return null;
        }

        try {
            return Base58.encode(serializedTransaction);
        } catch (error) {
            return null;
        }
    }

    serializedTransactionFor(transaction) {
        if (!transaction || typeof transaction.serialize !== "function") {
            return null;
        }

        try {
            return transaction.serialize({
                requireAllSignatures: false,
                verifySignatures: false,
            });
        } catch (error) {
            try {
                return transaction.serialize();
            } catch (fallbackError) {
                return null;
            }
        }
    }

    serializedMessageFor(transaction) {
        // Legacy transactions expose `serializeMessage()`, while versioned
        // transactions expose the serialized message through `message.serialize()`.
        if (transaction && typeof transaction.serializeMessage === "function") {
            return transaction.serializeMessage();
        }

        if (transaction && transaction.message && typeof transaction.message.serialize === "function") {
            return transaction.message.serialize();
        }

        throw new ProviderRpcError(4200, "Big Wallet does not support this Solana transaction format");
    }

    signTransaction(transaction) {
        this.assertCanSignTransactionObject(transaction, "Big Wallet could not sign this Solana transaction");
        const params = { message: this.encodedMessageFor(transaction) };
        const payload = { method: "signTransaction", params: params, id: Utils.genId() };
        this.trackPendingRequest(payload.id, { transactions: [transaction] });
        return this.request(payload);
    }

    signAllTransactions(transactions) {
        transactions.forEach((transaction) => {
            this.assertCanSignTransactionObject(transaction, "Big Wallet could not sign this Solana transaction batch");
        });
        const messages = transactions.map((transaction) => {
            return this.encodedMessageFor(transaction);
        });
        const payload = { method: "signAllTransactions", params: { messages: messages }, id: Utils.genId() };
        this.trackPendingRequest(payload.id, { transactions: transactions });
        return this.request(payload);
    }

    signAndSendTransaction(transaction, options) {
        const params = { transaction: transaction };
        if (typeof options !== "undefined") {
            params.options = options;
        }
        const payload = { method: "signAndSendTransaction", params: params, id: Utils.genId() };
        this.trackPendingRequest(payload.id);
        return this.request(payload);
    }

    signMessage(encodedMessage, display) {
        const params = { message: encodedMessage };
        if (typeof display !== "undefined") {
            params.display = display;
        }
        const payload = { method: "signMessage", params: params, id: Utils.genId() };
        this.trackPendingRequest(payload.id, { respondWithBuffer: true });
        return this.request(payload);
    }

    postPreparedPayload(payload, prepared) {
        payload.params = prepared.params;
        if (prepared.pendingRequestMetadata && !this.pendingRequests.has(payload.id)) {
            this.trackPendingRequest(payload.id, prepared.pendingRequestMetadata);
        }
        this.postMessage(payload.method, payload.id, payload);
    }

    request(payload) {
        if (payload.method === "disconnect") {
            return this.disconnect();
        }

        const originalId = payload.id;
        this.idMapping.tryFixId(payload);
        this.movePendingRequest(originalId, payload.id);
        return new Promise((resolve, reject) => {
            if (!payload.id) {
                payload.id = Utils.genId();
            }

            if (payload.method === "signMessage" && !this.pendingRequests.has(payload.id)) {
                this.trackPendingRequest(payload.id, { respondWithBuffer: true });
            }

            this.callbacks.set(payload.id, (error, data) => {
                setTimeout(() => {
                    if (error) {
                        reject(error);
                    } else {
                        resolve(data);
                    }
                }, 1);
            });

            switch (payload.method) {
            case "connect":
            case "signMessage":
            case "signTransaction":
            case "signAllTransactions":
            case "signAndSendTransaction":
                return this.processPayloadSafely(payload);
            default:
                this.sendError(payload.id, new ProviderRpcError(4200, `Big Wallet does not support ${payload.method}`));
            }
        });
    }

    processPayloadSafely(payload) {
        try {
            this.processPayload(payload);
        } catch (error) {
            this.sendError(payload.id, error);
        }
    }

    processPayload(payload) {
        if (!this.didGetLatestConfiguration) {
            this.pendingPayloads.push(payload);
            return;
        }

        switch (payload.method) {
        case "connect":
            if (!this.publicKey) {
                if (payload.params && payload.params.onlyIfTrusted) {
                    this.sendError(payload.id, new ProviderRpcError(4100, "Click a button to connect"));
                } else {
                    this.postMessage("connect", payload.id, {});
                }
            } else {
                this.isConnected = true;
                this.emitConnect(this.publicKey);
                this.sendResponse(payload.id, { publicKey: this.publicKey });
            }
            break;
        case "signMessage":
            payload.params = this.preparedSignMessageParams(payload.params);
            this.postMessage("signMessage", payload.id, payload);
            break;
        case "signTransaction": {
            this.postPreparedPayload(payload, this.preparedSignTransactionParams(payload.params));
            break;
        }
        case "signAllTransactions": {
            this.postPreparedPayload(payload, this.preparedSignAllTransactionsParams(payload.params));
            break;
        }
        case "signAndSendTransaction": {
            this.postPreparedPayload(payload, this.preparedSignAndSendTransactionParams(payload.params));
            break;
        }
        default:
            this.sendError(payload.id, new ProviderRpcError(4200, `Big Wallet does not support ${payload.method}`));
        }
    }

    emitConnect(publicKey) {
        this.emit("connect", publicKey);
    }

    trackPendingRequest(id, metadata = {}) {
        const publicKey = this.publicKey ? this.publicKey.toString() : null;
        this.pendingRequests.set(id, {
            publicKey: publicKey,
            ...metadata,
        });
    }

    movePendingRequest(oldId, newId) {
        if (typeof oldId === "undefined" || oldId === newId || !this.pendingRequests.has(oldId)) {
            return;
        }

        const pendingRequest = this.pendingRequests.get(oldId);
        this.pendingRequests.delete(oldId);
        this.pendingRequests.set(newId, pendingRequest);
    }

    publicKeyForPendingRequest(pendingRequest) {
        if (pendingRequest && typeof pendingRequest.publicKey === "string") {
            return new PublicKey(pendingRequest.publicKey);
        }

        return this.publicKey;
    }

    shouldDisconnectForUnauthorizedResponse(response, pendingRequest) {
        if (response.errorCode !== 4100 || !this.publicKey) {
            return false;
        }

        if (typeof response.errorPublicKey === "string") {
            return this.publicKey.toString() === response.errorPublicKey;
        }

        return pendingRequest &&
            typeof pendingRequest.publicKey === "string" &&
            this.publicKey.toString() === pendingRequest.publicKey;
    }

    signingPublicKeyForTransaction(transaction, publicKey) {
        if (!transaction || !publicKey) {
            return publicKey;
        }

        const signerPublicKeys = this.versionedTransactionSignerPublicKeys(transaction);
        if (signerPublicKeys) {
            for (let index = 0; index < signerPublicKeys.length; index++) {
                if (this.isMatchingPublicKey(publicKey, signerPublicKeys[index])) {
                    return signerPublicKeys[index];
                }
            }
        }

        if (Array.isArray(transaction.signatures)) {
            for (let index = 0; index < transaction.signatures.length; index++) {
                const signature = transaction.signatures[index];
                if (this.isMatchingPublicKey(publicKey, signature && signature.publicKey)) {
                    return signature.publicKey;
                }
            }
        }

        return publicKey;
    }

    attachCurrentPublicKeyToPendingRequest(id) {
        const pendingRequest = this.pendingRequests.get(id);
        if (!pendingRequest || pendingRequest.publicKey !== null || !this.publicKey) {
            return;
        }

        pendingRequest.publicKey = this.publicKey.toString();
        this.pendingRequests.set(id, pendingRequest);
    }

    applySignatureToTransaction(id, transaction, publicKey, encodedSignature) {
        try {
            const signature = Base58.decode(encodedSignature);
            if (typeof transaction.addSignature === "function") {
                transaction.addSignature(this.signingPublicKeyForTransaction(transaction, publicKey), signature);
                return true;
            }

            if (this.applySignatureToVersionedTransaction(transaction, publicKey, signature)) {
                return true;
            }
        } catch (error) {
        }

        this.sendError(id, new ProviderRpcError(4200, "Big Wallet could not apply the Solana signature"));
        return false;
    }

    applySignatureToVersionedTransaction(transaction, publicKey, signature) {
        if (signature.length !== 64 || !this.canSetVersionedTransactionSignature(transaction)) {
            return false;
        }

        const signerIndex = this.signerIndexForVersionedTransaction(transaction, publicKey);
        if (signerIndex === null || signerIndex >= transaction.signatures.length) {
            return false;
        }

        transaction.signatures[signerIndex] = signature;
        return true;
    }

    signerIndexForVersionedTransaction(transaction, publicKey) {
        if (!publicKey || !this.canSetVersionedTransactionSignature(transaction)) {
            return null;
        }

        const signerPublicKeys = this.versionedTransactionSignerPublicKeys(transaction);
        for (let index = 0; index < signerPublicKeys.length; index++) {
            const signerPublicKey = signerPublicKeys[index];
            if (this.isMatchingPublicKey(publicKey, signerPublicKey)) {
                return index;
            }
        }

        return null;
    }

    processBigWalletResponse(id, response) {
        if (response.name === "didLoadLatestConfiguration") {
            this.didGetLatestConfiguration = true;

            if ("publicKey" in response) {
                this.publicKey = new PublicKey(response.publicKey);
                this.isConnected = true;
            } else {
                this.publicKey = null;
                this.isConnected = false;
            }

            for (const payload of this.pendingPayloads) {
                this.processPayloadSafely(payload);
            }
            this.pendingPayloads = [];
            return;
        }

        const pendingRequest = this.pendingRequests.get(id);
        const requestPublicKey = this.publicKeyForPendingRequest(pendingRequest);

        if ("publicKey" in response) {
            this.isConnected = true;
            const publicKey = new PublicKey(response.publicKey);
            this.publicKey = publicKey;
            if (response.name !== "switchAccount") {
                this.sendResponse(id, { publicKey: publicKey });
            }
            this.emitConnect(publicKey);
            if (response.name === "switchAccount") {
                this.emit("accountChanged", publicKey);
            }
        } else if ("result" in response) {
            if (response.name === "signTransaction" &&
                pendingRequest &&
                Array.isArray(pendingRequest.transactions)) {
                if (!requestPublicKey) {
                    this.sendError(id, new ProviderRpcError(4100, "provider is not ready"));
                    return;
                }
                const transaction = pendingRequest.transactions[0];
                if (!this.applySignatureToTransaction(id, transaction, requestPublicKey, response.result)) {
                    return;
                }
                this.sendResponse(id, transaction);
            } else if (pendingRequest && pendingRequest.respondWithBuffer === true) {
                const signature = Utils.messageToBuffer(Base58.decode(response.result));
                this.sendResponse(id, { signature: signature, publicKey: requestPublicKey });
            } else {
                this.sendResponse(id, { signature: response.result, publicKey: requestPublicKey });
            }
        } else if ("results" in response) {
            if (!Array.isArray(response.results)) {
                this.sendError(id, new ProviderRpcError(4200, "Big Wallet received an invalid Solana signature response"));
                return;
            }

            if (pendingRequest && Array.isArray(pendingRequest.transactions)) {
                if (!requestPublicKey) {
                    this.sendError(id, new ProviderRpcError(4100, "provider is not ready"));
                    return;
                }
                const transactions = pendingRequest.transactions;
                if (response.results.length !== transactions.length) {
                    this.sendError(id, new ProviderRpcError(4200, "Big Wallet received mismatched Solana transaction signatures"));
                    return;
                }

                for (let index = 0; index < response.results.length; index++) {
                    if (!this.applySignatureToTransaction(id, transactions[index], requestPublicKey, response.results[index])) {
                        return;
                    }
                }
                this.sendResponse(id, transactions);
            } else {
                this.sendResponse(id, {
                    signatures: response.results,
                    publicKey: requestPublicKey,
                });
            }
        } else if ("error" in response) {
            if (this.shouldDisconnectForUnauthorizedResponse(response, pendingRequest)) {
                this.performDisconnect();
            }
            this.sendError(id, response.error, response.errorCode);
        }
    }

    postMessage(handler, id, data) {
        if (handler !== "connect" && !this.publicKey) {
            this.sendError(id, new ProviderRpcError(4100, "provider is not ready"));
            return;
        }

        this.attachCurrentPublicKeyToPendingRequest(id);

        const publicKey = this.publicKey ? this.publicKey.toString() : "";
        const object = {
            object: data,
            publicKey: publicKey,
        };
        window.bigwallet.postMessage(handler, id, object, "solana");
    }

    sendResponse(id, result) {
        this.idMapping.tryPopId(id);
        this.pendingRequests.delete(id);
        const callback = this.callbacks.get(id);
        if (callback) {
            callback(null, result);
            this.callbacks.delete(id);
        } else {
            console.log(`callback id: ${id} not found`);
        }
    }

    providerError(error, code) {
        if (error instanceof Error) {
            return error;
        }

        if (error && typeof error === "object" && typeof error.code === "number") {
            return new ProviderRpcError(error.code, error.message || "Big Wallet request failed");
        }

        if (typeof code === "number") {
            return new ProviderRpcError(code, error || "Big Wallet request failed");
        }

        if (typeof error === "string" && error.toLowerCase() === "canceled") {
            return new ProviderRpcError(4001, error);
        }

        return new Error(error);
    }

    sendError(id, error, code) {
        this.idMapping.tryPopId(id);
        this.pendingRequests.delete(id);
        const callback = this.callbacks.get(id);
        if (callback) {
            callback(this.providerError(error, code), null);
            this.callbacks.delete(id);
        }
    }

}

module.exports = BigWalletSolana;
