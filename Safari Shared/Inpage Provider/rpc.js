// ∅ 2026 lil org

"use strict";

import { outboundJSONSerialize } from "./outbound_snapshot";

const applyFunction = Reflect.apply;
const createObjectNormally = Object.create;
const freezeObjectNormally = Object.freeze;
const getOwnPropertyDescriptorNormally = Object.getOwnPropertyDescriptor;
const getWeakMapValueNormally = WeakMap.prototype.get;
const setWeakMapValueNormally = WeakMap.prototype.set;
const TypeErrorConstructor = TypeError;
const rpcStates = new WeakMap;

function rpcState(server) {
    return applyFunction(getWeakMapValueNormally, rpcStates, [server]);
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
        applyFunction(setWeakMapValueNormally, rpcStates, [this,
            freezeObjectNormally({
                chainId,
                providerGeneration,
                transport,
            })
        ]);
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
