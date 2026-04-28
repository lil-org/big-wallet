// ∅ 2026 lil org

"use strict";

import Utils from "./utils";
import IdMapping from "./id_mapping";
import Base58 from "./base58";
import ProviderRpcError from "./error";
import { EventEmitter } from "events";

const walletName = "Big Wallet";
const walletStandardVersion = "1.0.0";
const solanaSignMessageFeatureVersion = "1.1.0";
const solanaMainnetChain = "solana:mainnet";
const solanaDevnetChain = "solana:devnet";
const solanaTestnetChain = "solana:testnet";
const solanaChains = Object.freeze([solanaMainnetChain, solanaDevnetChain, solanaTestnetChain]);
const solanaSupportedTransactionVersions = Object.freeze(["legacy", 0]);
const walletStandardRegisterEvent = "wallet-standard:register-wallet";
const walletStandardAppReadyEvent = "wallet-standard:app-ready";
const standardChangeEvent = "change";
const standardConnect = "standard:connect";
const standardDisconnect = "standard:disconnect";
const standardEvents = "standard:events";
const solanaSignAndSendTransaction = "solana:signAndSendTransaction";
const solanaSignTransaction = "solana:signTransaction";
const solanaSignMessage = "solana:signMessage";
const invalidSolanaMessageRequest = "Big Wallet could not normalize this Solana message request";
const invalidSolanaSignatureResponse = "Big Wallet received an invalid Solana signature response";
const invalidSolanaTransactionBatchRequest = "Big Wallet could not normalize this Solana transaction batch";
const invalidSolanaTransactionRequest = "Big Wallet could not normalize this Solana transaction request";
const invalidSolanaTransactionOptions = "Big Wallet received unsupported Solana transaction options";
const ambiguousSolanaTransactionParams = "Big Wallet received ambiguous Solana transaction params";
const mismatchedSolanaTransactionParams = "Big Wallet received mismatched Solana transaction params";
const mismatchedSolanaTransactionSignatures = "Big Wallet received mismatched Solana transaction signatures";
const providerNotReadyMessage = "provider is not ready";
const solanaSignatureApplicationError = "Big Wallet could not apply the Solana signature";
const unsupportedSolanaChain = "Big Wallet does not support this Solana chain";
const solanaAccountFeatures = Object.freeze([
    solanaSignAndSendTransaction,
    solanaSignTransaction,
    solanaSignMessage,
]);

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
        this.standardChangeListeners = new Set();
        this.standardAccountsByAddress = new Map();
        this.standardRegisteredHosts = typeof WeakSet !== "undefined" ? new WeakSet() : null;
        this.standardWalletFeatures = null;
        this.standardWallet = null;

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
        this.standardSignAndSendTransaction = this.standardSignAndSendTransaction.bind(this);
        this.standardSignTransaction = this.standardSignTransaction.bind(this);
        this.standardSignMessage = this.standardSignMessage.bind(this);
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
        this.standardAccountsByAddress.clear();
        if (didChangeAccount) {
            this.emit("accountChanged", null);
        }
        this.emit("disconnect");
        if (didChangeAccount) {
            this.emitStandardChange({ accounts: this.standardAccounts() });
        }
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

    standardPublicKeyBytes(publicKey) {
        return new Uint8Array(publicKey.toBytes());
    }

    standardAccountForPublicKey(publicKey) {
        const address = publicKey.toString();
        let account = this.standardAccountsByAddress.get(address);
        if (!account) {
            const publicKeyBytes = this.standardPublicKeyBytes(publicKey);
            account = Object.freeze({
                address: address,
                get publicKey() {
                    return publicKeyBytes.slice();
                },
                chains: solanaChains,
                features: solanaAccountFeatures,
                label: walletName,
            });
            this.standardAccountsByAddress.set(address, account);
        }
        return account;
    }

    standardAccounts() {
        return this.publicKey ? [this.standardAccountForPublicKey(this.publicKey)] : [];
    }

    currentPublicKeyString() {
        return this.publicKey ? this.publicKey.toString() : null;
    }

    emitStandardAccountChangeIfNeeded(previousPublicKey) {
        if (previousPublicKey !== this.currentPublicKeyString()) {
            if (previousPublicKey) {
                this.standardAccountsByAddress.delete(previousPublicKey);
            }
            this.emitStandardChange({ accounts: this.standardAccounts() });
        }
    }

    standardFeatures() {
        if (this.standardWalletFeatures) {
            return this.standardWalletFeatures;
        }

        this.standardWalletFeatures = Object.freeze({
            [standardConnect]: Object.freeze({
                version: walletStandardVersion,
                connect: this.standardConnect,
            }),
            [standardDisconnect]: Object.freeze({
                version: walletStandardVersion,
                disconnect: this.standardDisconnect,
            }),
            [standardEvents]: Object.freeze({
                version: walletStandardVersion,
                on: this.standardOn,
            }),
            [solanaSignAndSendTransaction]: Object.freeze({
                version: walletStandardVersion,
                supportedTransactionVersions: solanaSupportedTransactionVersions,
                signAndSendTransaction: this.standardSignAndSendTransaction,
            }),
            [solanaSignTransaction]: Object.freeze({
                version: walletStandardVersion,
                supportedTransactionVersions: solanaSupportedTransactionVersions,
                signTransaction: this.standardSignTransaction,
            }),
            [solanaSignMessage]: Object.freeze({
                version: solanaSignMessageFeatureVersion,
                signMessage: this.standardSignMessage,
            }),
        });
        return this.standardWalletFeatures;
    }

    registerWalletStandard(options) {
        if (this.standardWallet) {
            return this.standardWallet;
        }

        const icon = options && options.icon ? options.icon : "";
        const provider = this;
        this.standardWallet = Object.freeze({
            get version() {
                return walletStandardVersion;
            },
            get name() {
                return walletName;
            },
            get icon() {
                return icon;
            },
            get chains() {
                return solanaChains;
            },
            get features() {
                return provider.standardFeatures();
            },
            get accounts() {
                return provider.standardAccounts();
            },
        });

        this.dispatchWalletStandardRegistration(this.standardWallet);
        return this.standardWallet;
    }

    dispatchWalletStandardRegistration(wallet) {
        const registeredHosts = this.standardRegisteredHosts;
        const callback = (registration) => {
            if (registration && typeof registration.register === "function") {
                if (registeredHosts && (typeof registration === "object" || typeof registration === "function")) {
                    if (registeredHosts.has(registration)) {
                        return;
                    }
                    registeredHosts.add(registration);
                }
                registration.register(wallet);
            }
        };
        try {
            window.dispatchEvent(new CustomEvent(walletStandardRegisterEvent, { detail: callback }));
        } catch (error) {
            try {
                const event = new Event(walletStandardRegisterEvent, {
                    bubbles: false,
                    cancelable: false,
                    composed: false,
                });
                Object.defineProperty(event, "detail", { value: callback });
                window.dispatchEvent(event);
            } catch (fallbackError) {
                console.error("Big Wallet: wallet-standard registration failed", fallbackError);
            }
        }

        try {
            window.addEventListener(walletStandardAppReadyEvent, (event) => {
                callback(event.detail);
            });
        } catch (error) {
            console.error("Big Wallet: wallet-standard app-ready listener failed", error);
        }

        try {
            window.navigator.wallets = window.navigator.wallets || [];
            window.navigator.wallets.push(callback);
        } catch (error) {
            // Some injected contexts expose a read-only navigator; event registration remains authoritative.
        }
    }

    standardOn(event, listener) {
        if (event !== standardChangeEvent) {
            return () => {};
        }

        this.standardChangeListeners.add(listener);
        return () => {
            this.standardChangeListeners.delete(listener);
        };
    }

    emitStandardChange(properties) {
        for (const listener of this.standardChangeListeners) {
            try {
                listener(properties);
            } catch (error) {
                console.error("Big Wallet: wallet-standard change listener failed", error);
            }
        }
    }

    async standardConnect(input) {
        if (input && input.silent === true) {
            if (this.didGetLatestConfiguration && !this.publicKey) {
                return { accounts: [] };
            }

            try {
                await this.connect({ onlyIfTrusted: true });
            } catch (error) {
                if (error && error.code === 4100) {
                    return { accounts: [] };
                }
                throw error;
            }

            return { accounts: this.standardAccounts() };
        }

        await this.connect();
        return { accounts: this.standardAccounts() };
    }

    async standardDisconnect() {
        await this.disconnect();
    }

    assertStandardAccount(account) {
        if (!this.publicKey || !account || account.address !== this.publicKey.toString()) {
            throw new ProviderRpcError(4100, providerNotReadyMessage);
        }
    }

    assertSupportedStandardChain(chain, isRequired) {
        if ((!isRequired && typeof chain === "undefined") || solanaChains.includes(chain)) {
            return;
        }

        throw new ProviderRpcError(4200, unsupportedSolanaChain);
    }

    normalizedStandardBytes(value, errorMessage) {
        const bytes = this.bytesFor(value);
        if (bytes) {
            return bytes;
        }

        throw new ProviderRpcError(4200, errorMessage);
    }

    standardBytesSnapshot(value, errorMessage) {
        return new Uint8Array(this.normalizedStandardBytes(value, errorMessage));
    }

    standardSignatureBytes(value) {
        const signature = this.standardBytesSnapshot(value, invalidSolanaSignatureResponse);
        if (signature.length !== 64) {
            throw new ProviderRpcError(4200, invalidSolanaSignatureResponse);
        }

        return signature;
    }

    standardBase58Signature(value) {
        try {
            return this.standardSignatureBytes(Base58.decode(value));
        } catch (error) {
            if (error instanceof ProviderRpcError) {
                throw error;
            }
            throw new ProviderRpcError(4200, invalidSolanaSignatureResponse);
        }
    }

    standardSignAndSendOptions(input) {
        const options = { ...((input && input.options) || {}) };
        if (typeof options.mode !== "undefined" && options.mode !== "serial") {
            throw new ProviderRpcError(4200, invalidSolanaTransactionOptions);
        }

        if (input && input.chain) {
            options.bigWalletCluster = input.chain;
        }

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
                return { value: value, offset: cursor };
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

        const accountCount = this.decodeShortVec(messageBytes, accountCountOffset);
        if (accountCount.value < requiredSignaturesCount) {
            throw new ProviderRpcError(4200, invalidSolanaTransactionRequest);
        }

        const accountKeysStart = accountCount.offset;
        const accountKeysLength = accountCount.value * 32;
        if (accountKeysStart + accountKeysLength > messageBytes.length) {
            throw new ProviderRpcError(4200, invalidSolanaTransactionRequest);
        }

        for (let index = 0; index < requiredSignaturesCount; index++) {
            const keyOffset = accountKeysStart + index * 32;
            let didMatch = true;
            for (let byteIndex = 0; byteIndex < 32; byteIndex++) {
                if (messageBytes[keyOffset + byteIndex] !== publicKeyBytes[byteIndex]) {
                    didMatch = false;
                    break;
                }
            }
            if (didMatch) {
                return {
                    requiredSignaturesCount: requiredSignaturesCount,
                    signerIndex: index,
                };
            }
        }

        throw new ProviderRpcError(4200, invalidSolanaTransactionRequest);
    }

    preparedStandardTransaction(transaction) {
        const transactionBytes = this.standardBytesSnapshot(transaction, invalidSolanaTransactionRequest);
        const signatureCount = this.decodeShortVec(transactionBytes, 0);
        if (signatureCount.value <= 0) {
            throw new ProviderRpcError(4200, invalidSolanaTransactionRequest);
        }

        const signaturesStart = signatureCount.offset;
        const messageStart = signaturesStart + signatureCount.value * 64;
        if (messageStart >= transactionBytes.length) {
            throw new ProviderRpcError(4200, invalidSolanaTransactionRequest);
        }

        const messageBytes = transactionBytes.slice(messageStart);
        const signerPublicKey = this.standardPublicKeyBytes(this.publicKey);
        const signerDetails = this.signerDetailsForMessage(messageBytes, signerPublicKey);
        if (signatureCount.value !== signerDetails.requiredSignaturesCount ||
            signerDetails.signerIndex >= signatureCount.value) {
            throw new ProviderRpcError(4200, invalidSolanaTransactionRequest);
        }

        return {
            transactionBytes: transactionBytes,
            messageBytes: messageBytes,
            signatureOffset: signaturesStart + signerDetails.signerIndex * 64,
        };
    }

    async standardSignMessage(...inputs) {
        const outputs = [];
        for (const input of inputs) {
            this.assertStandardAccount(input && input.account);
            const message = this.standardBytesSnapshot(input.message, invalidSolanaMessageRequest);
            const response = await this.signMessage(message);
            outputs.push({
                signedMessage: message,
                signature: this.standardSignatureBytes(response.signature),
            });
        }
        return outputs;
    }

    async standardSignTransaction(...inputs) {
        const outputs = [];
        for (const input of inputs) {
            this.assertStandardAccount(input && input.account);
            this.assertSupportedStandardChain(input && input.chain, false);
            const prepared = this.preparedStandardTransaction(input.transaction);
            const payload = this.signTransactionPayload(Base58.encode(prepared.messageBytes));
            this.trackPendingRequest(payload.id);
            const response = await this.request(payload);
            const signature = this.standardBase58Signature(response.signature);

            const signedTransaction = new Uint8Array(prepared.transactionBytes);
            signedTransaction.set(signature, prepared.signatureOffset);
            outputs.push({ signedTransaction: signedTransaction });
        }
        return outputs;
    }

    async standardSignAndSendTransaction(...inputs) {
        const preparedInputs = inputs.map((input) => {
            this.assertStandardAccount(input && input.account);
            this.assertSupportedStandardChain(input && input.chain, true);
            return {
                account: input.account,
                transaction: this.standardBytesSnapshot(input.transaction, invalidSolanaTransactionRequest),
                options: this.standardSignAndSendOptions(input),
            };
        });

        const outputs = [];
        for (const preparedInput of preparedInputs) {
            const response = await this.signAndSendTransaction(preparedInput.transaction, preparedInput.options);
            outputs.push({
                signature: this.standardBase58Signature(response.signature),
            });
        }
        return outputs;
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
            throw new ProviderRpcError(4200, ambiguousSolanaTransactionParams);
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
        const errorMessage = invalidSolanaMessageRequest;

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
                throw new ProviderRpcError(4200, mismatchedSolanaTransactionParams);
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
            this.assertCanSignTransactionObject(transaction, invalidSolanaTransactionRequest);
            const derivedMessage = this.encodedMessageFor(transaction);
            this.normalizeDerivedMessage(normalizedParams,
                                         derivedMessage,
                                         invalidSolanaTransactionRequest);
            pendingRequestMetadata = { transactions: [transaction] };
            delete normalizedParams.transaction;
        } else if ("message" in normalizedParams) {
            normalizedParams.message = this.normalizedBase58Value(normalizedParams.message, invalidSolanaTransactionRequest);
        } else {
            throw new ProviderRpcError(4200, invalidSolanaTransactionRequest);
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
                this.assertCanSignTransactionObject(transaction, invalidSolanaTransactionBatchRequest);
            });
            const derivedMessages = transactions.map((transaction) => {
                return this.encodedMessageFor(transaction);
            });

            if (suppliedMessageParamName) {
                if (!Array.isArray(suppliedMessages) || suppliedMessages.length !== derivedMessages.length) {
                    throw new ProviderRpcError(4200, mismatchedSolanaTransactionParams);
                }

                const normalizedMessages = this.normalizedBase58Messages(suppliedMessages,
                                                                        invalidSolanaTransactionBatchRequest);
                for (let index = 0; index < normalizedMessages.length; index++) {
                    if (normalizedMessages[index] !== derivedMessages[index]) {
                        throw new ProviderRpcError(4200, mismatchedSolanaTransactionParams);
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
                                                                      invalidSolanaTransactionBatchRequest);
            delete normalizedParams.message;
        } else {
            throw new ProviderRpcError(4200, invalidSolanaTransactionBatchRequest);
        }

        return {
            params: normalizedParams,
            pendingRequestMetadata: pendingRequestMetadata,
        };
    }

    preparedSignAndSendTransactionParams(params) {
        const normalizedParams = { ...(params || {}) };
        const errorMessage = invalidSolanaTransactionRequest;

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

    signTransactionPayload(message) {
        return { method: "signTransaction", params: { message: message }, id: Utils.genId() };
    }

    signTransaction(transaction) {
        this.assertCanSignTransactionObject(transaction, "Big Wallet could not sign this Solana transaction");
        const payload = this.signTransactionPayload(this.encodedMessageFor(transaction));
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

        this.sendError(id, new ProviderRpcError(4200, solanaSignatureApplicationError));
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
            const previousPublicKey = this.currentPublicKeyString();
            this.didGetLatestConfiguration = true;

            if ("publicKey" in response) {
                this.publicKey = new PublicKey(response.publicKey);
                this.isConnected = true;
            } else {
                this.publicKey = null;
                this.isConnected = false;
            }

            this.emitStandardAccountChangeIfNeeded(previousPublicKey);

            for (const payload of this.pendingPayloads) {
                this.processPayloadSafely(payload);
            }
            this.pendingPayloads = [];
            return;
        }

        const pendingRequest = this.pendingRequests.get(id);
        const requestPublicKey = this.publicKeyForPendingRequest(pendingRequest);

        if ("publicKey" in response) {
            const previousPublicKey = this.currentPublicKeyString();
            this.isConnected = true;
            const publicKey = new PublicKey(response.publicKey);
            this.publicKey = publicKey;
            if (response.name !== "switchAccount") {
                this.sendResponse(id, { publicKey: publicKey });
            }
            this.emitConnect(publicKey);
            this.emitStandardAccountChangeIfNeeded(previousPublicKey);
            if (response.name === "switchAccount") {
                this.emit("accountChanged", publicKey);
            }
        } else if ("result" in response) {
            if (response.name === "signTransaction" &&
                pendingRequest &&
                Array.isArray(pendingRequest.transactions)) {
                if (!requestPublicKey) {
                    this.sendError(id, new ProviderRpcError(4100, providerNotReadyMessage));
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
                this.sendError(id, new ProviderRpcError(4200, invalidSolanaSignatureResponse));
                return;
            }

            if (pendingRequest && Array.isArray(pendingRequest.transactions)) {
                if (!requestPublicKey) {
                    this.sendError(id, new ProviderRpcError(4100, providerNotReadyMessage));
                    return;
                }
                const transactions = pendingRequest.transactions;
                if (response.results.length !== transactions.length) {
                    this.sendError(id, new ProviderRpcError(4200, mismatchedSolanaTransactionSignatures));
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
            this.sendError(id, response.error, response.errorCode, this.errorDataForResponse(response));
        }
    }

    postMessage(handler, id, data) {
        if (handler !== "connect" && !this.publicKey) {
            this.sendError(id, new ProviderRpcError(4100, providerNotReadyMessage));
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

    errorDataForResponse(response) {
        if (typeof response.errorSignature === "string") {
            return { signature: response.errorSignature };
        }

        return undefined;
    }

    providerError(error, code, data) {
        if (error instanceof Error) {
            if (typeof data !== "undefined" &&
                typeof error.data === "undefined" &&
                typeof error.code === "number") {
                return new ProviderRpcError(error.code, error.message || "Big Wallet request failed", data);
            }
            return error;
        }

        if (error && typeof error === "object" && typeof error.code === "number") {
            return new ProviderRpcError(error.code, error.message || "Big Wallet request failed", data);
        }

        if (typeof code === "number") {
            return new ProviderRpcError(code, error || "Big Wallet request failed", data);
        }

        if (typeof error === "string" && error.toLowerCase() === "canceled") {
            return new ProviderRpcError(4001, error);
        }

        return new Error(error);
    }

    sendError(id, error, code, data) {
        this.idMapping.tryPopId(id);
        this.pendingRequests.delete(id);
        const callback = this.callbacks.get(id);
        if (callback) {
            callback(this.providerError(error, code, data), null);
            this.callbacks.delete(id);
        }
    }

}

module.exports = BigWalletSolana;
