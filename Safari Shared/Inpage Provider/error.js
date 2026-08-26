// ∅ 2026 lil org

"use strict";

import BigWalletBridgeWire from "../Resources/bridge_wire";

const {
    PROVIDER_REPLACED_ERROR_CODE,
    PROVIDER_REPLACED_MESSAGE,
} = BigWalletBridgeWire;

class ProviderRpcError extends Error {
    constructor(code, message, data) {
        super();
        this.code = code;
        this.message = message;
        if (typeof data !== "undefined") {
            this.data = data;
        }
    }
    
    toString() {
        return `${this.message} (${this.code})`;
    }
}

const fallbackMessage = "Big Wallet request failed";

const ethereumPolicy = Object.freeze({
    dataForObject(error, data) {
        return typeof data === "undefined" ? error.data : data;
    },
    message(message) {
        return typeof message === "string" ? message : fallbackMessage;
    },
});

const solanaPolicy = Object.freeze({
    dataForObject(error, data) {
        return data;
    },
    message(message) {
        return message || fallbackMessage;
    },
});

function normalizeProviderError(error, code, data, policy) {
    if (error instanceof Error) {
        if (typeof data !== "undefined" &&
            typeof error.data === "undefined" &&
            typeof error.code === "number") {
            return new ProviderRpcError(
                error.code,
                policy.message(error.message),
                data
            );
        }
        return error;
    }

    if (error && typeof error === "object" && typeof error.code === "number") {
        return new ProviderRpcError(
            error.code,
            policy.message(error.message),
            policy.dataForObject(error, data)
        );
    }

    if (typeof code === "number") {
        return new ProviderRpcError(code, policy.message(error), data);
    }

    if (typeof error === "string" && error.toLowerCase() === "canceled") {
        return new ProviderRpcError(4001, error);
    }

    return new Error(error);
}

function decodeProviderErrorData(encodedData) {
    if (typeof encodedData !== "string") {
        return undefined;
    }

    try {
        return JSON.parse(encodedData);
    } catch {
        return undefined;
    }
}

function normalizeEthereumProviderError(error, code, data) {
    return normalizeProviderError(error, code, data, ethereumPolicy);
}

function normalizeSolanaProviderError(error, code, data) {
    return normalizeProviderError(error, code, data, solanaPolicy);
}

function providerReplacementError() {
    return new ProviderRpcError(
        PROVIDER_REPLACED_ERROR_CODE,
        PROVIDER_REPLACED_MESSAGE
    );
}

export {
    decodeProviderErrorData,
    normalizeEthereumProviderError,
    normalizeSolanaProviderError,
    providerReplacementError,
};
export default ProviderRpcError;
