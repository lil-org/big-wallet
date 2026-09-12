// ∅ 2026 lil org

"use strict";

import {
    applyFunction,
    createObjectNormally,
    freezeObjectNormally,
    getOwnPropertyDescriptorNormally,
    TypeErrorConstructor,
    getWeakMapValue,
    setWeakMapValue,
} from "./intrinsics";

import { outboundJSONSerialize } from "./outbound_snapshot";

const rpcStates = new WeakMap;

function rpcState(server) {
    return getWeakMapValue(rpcStates, server);
}

function requestSnapshot(payload) {
    if (!payload || typeof payload !== "object") {
        throw new TypeErrorConstructor("RPC payload must be an object");
    }
    const request = createObjectNormally(null);
    request.id = payload.id;
    request.jsonrpc = "2.0";
    request.method = payload.method;
    const paramsDescriptor = getOwnPropertyDescriptorNormally(
        payload,
        "params"
    );
    if (paramsDescriptor) {
        request.params = payload.params;
    }
    return request;
}

class RPCServer {

    constructor(chainId, providerGeneration, transport) {
        if (typeof transport !== "function") {
            throw new TypeErrorConstructor("RPC transport must be a function");
        }
        setWeakMapValue(rpcStates, this, freezeObjectNormally({
            chainId,
            providerGeneration,
            transport,
        }));
    }

    get chainId() {
        return rpcState(this)?.chainId;
    }

    get providerGeneration() {
        return rpcState(this)?.providerGeneration;
    }

    call(payload, isCurrent) {
        const state = rpcState(this);
        if (!state) { return false; }
        if (typeof isCurrent === "function" && !isCurrent()) {
            return false;
        }
        const request = requestSnapshot(payload);
        const id = request.id;
        const body = outboundJSONSerialize(request);
        const message = createObjectNormally(null);
        message.body = body;
        message.chainId = state.chainId;
        message.id = id;
        message.subject = "rpc";
        if (typeof isCurrent === "function" && !isCurrent()) {
            return false;
        }
        const posted = applyFunction(state.transport, undefined, [
            message,
            state.providerGeneration,
        ]);
        return posted !== false;
    }
}

export { RPCServer };
export default RPCServer;
