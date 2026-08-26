// ∅ 2026 lil org

"use strict";

const applyFunction = Reflect.apply;
const createObjectNormally = Object.create;
const hasOwnPropertyNormally = Object.prototype.hasOwnProperty;
const isArrayNormally = Array.isArray;
const isFiniteNormally = Number.isFinite;
const malformedResponseCode = -32603;
const malformedResponseMessage = "Failed to process RPC response";

function hasOwnProperty(object, name) {
    return applyFunction(hasOwnPropertyNormally, object, [name]);
}

function validId(value) {
    return typeof value === "number" && isFiniteNormally(value);
}

function responseWith(id, name, value) {
    const response = createObjectNormally(null);
    response.id = id;
    response[name] = value;
    return response;
}

function canonicalError(code, message, data, hasData) {
    const error = createObjectNormally(null);
    error.code = code;
    error.message = message;
    if (hasData) { error.data = data; }
    return error;
}

function failedRPCResponse(id) {
    return responseWith(
        id,
        "error",
        canonicalError(
            malformedResponseCode,
            malformedResponseMessage,
            undefined,
            false
        )
    );
}

function normalizedError(response, rawError) {
    let code;
    let data;
    let hasData = false;
    let message;
    if (rawError && typeof rawError === "object") {
        if (hasOwnProperty(rawError, "code")) {
            const rawCode = rawError.code;
            if (validId(rawCode)) { code = rawCode; }
        }
        if (hasOwnProperty(rawError, "message")) {
            const rawMessage = rawError.message;
            if (typeof rawMessage === "string") { message = rawMessage; }
        }
        if (hasOwnProperty(rawError, "data")) {
            data = rawError.data;
            hasData = true;
        }
    } else if (typeof rawError === "string") {
        message = rawError;
    }
    if (typeof code === "undefined" &&
        hasOwnProperty(response, "errorCode")) {
        const errorCode = response.errorCode;
        if (validId(errorCode)) { code = errorCode; }
    }
    return canonicalError(
        typeof code === "undefined" ? malformedResponseCode : code,
        typeof message === "undefined" ? malformedResponseMessage : message,
        data,
        hasData
    );
}

function normalizedRPCResponse(response, correlationId) {
    const hasCorrelation = typeof correlationId !== "undefined";
    if (hasCorrelation && !validId(correlationId)) { return undefined; }
    if (!response || typeof response !== "object" ||
        isArrayNormally(response)) {
        return hasCorrelation ? failedRPCResponse(correlationId) : undefined;
    }
    let id;
    try {
        if (!hasOwnProperty(response, "id")) {
            return hasCorrelation
                ? failedRPCResponse(correlationId)
                : undefined;
        }
        id = response.id;
    } catch {
        return hasCorrelation ? failedRPCResponse(correlationId) : undefined;
    }
    if (!validId(id)) {
        return hasCorrelation ? failedRPCResponse(correlationId) : undefined;
    }
    if (hasCorrelation && id !== correlationId) {
        return failedRPCResponse(correlationId);
    }
    try {
        const hasError = hasOwnProperty(response, "error");
        const hasResult = hasOwnProperty(response, "result");
        if (hasError === hasResult) { return failedRPCResponse(id); }
        return hasResult
            ? responseWith(id, "result", response.result)
            : responseWith(
                id,
                "error",
                normalizedError(response, response.error)
            );
    } catch {
        return failedRPCResponse(id);
    }
}

export { normalizedRPCResponse };
