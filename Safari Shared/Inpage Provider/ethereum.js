// ∅ 2026 lil org

"use strict";

import RPCServer from "./rpc";
import ProviderRpcError, {
    normalizeEthereumProviderError,
    providerReplacementError,
} from "./error";
import OperationRuntime from "./operation_runtime";
import {
    nativeJSONClone,
    outboundDataSnapshot,
} from "./outbound_snapshot";
import Utils from "./utils";
import { EventEmitter } from "events";
import isUtf8 from "isutf8";
import BigWalletBridgeWire from "../Resources/bridge_wire";

const applyFunction = Reflect.apply;
const isArrayNormally = Array.isArray;
const isSafeIntegerNormally = Number.isSafeInteger;
const createObjectNormally = Object.create;
const freezeObjectNormally = Object.freeze;
const getOwnPropertyDescriptorNormally = Object.getOwnPropertyDescriptor;
const getWeakMapValueNormally = WeakMap.prototype.get;
const hasOwnPropertyNormally = Object.prototype.hasOwnProperty;
const objectKeysNormally = Object.keys;
const eventAddListenerNormally = EventEmitter.prototype.addListener;
const eventOnNormally = EventEmitter.prototype.on;
const eventPrependListenerNormally = EventEmitter.prototype.prependListener;
const eventRemoveAllListenersNormally =
    EventEmitter.prototype.removeAllListeners;
const eventRemoveListenerNormally = EventEmitter.prototype.removeListener;
const pushArrayNormally = Array.prototype.push;
const rawListenersNormally = EventEmitter.prototype.rawListeners;
const setWeakMapValueNormally = WeakMap.prototype.set;
const spliceArrayNormally = Array.prototype.splice;
const bigIntegerNormally = BigInt;
const bigIntegerToStringNormally = BigInt.prototype.toString;
const setTimeoutNormally = setTimeout;
const providerStates = new WeakMap;
const invalidParametersMessage = "Invalid parameters";
const providerStateMessage = "Failed to update provider state";
const authorizationChangedMessage =
    "Authorization changed while the request was pending";

function hasOwnProperty(object, name) {
    return applyFunction(hasOwnPropertyNormally, object, [name]);
}

function stateFor(provider) {
    return applyFunction(getWeakMapValueNormally, providerStates, [provider]);
}

function dataProperty(object, name) {
    const descriptor = getOwnPropertyDescriptorNormally(object, name);
    return descriptor && "value" in descriptor
        ? descriptor.value
        : undefined;
}

function invalidParameters() {
    return new ProviderRpcError(-32602, invalidParametersMessage);
}

function providerStateError() {
    return new ProviderRpcError(-32603, providerStateMessage);
}

function authorizationChangedError() {
    return new ProviderRpcError(4100, authorizationChangedMessage);
}

function reportListenerError(error) {
    try {
        console.error("Big Wallet: Ethereum listener failed", error);
    } catch {
    }
}

function normalizedNetworkVersion(chainId) {
    const value = applyFunction(bigIntegerNormally, undefined, [chainId]);
    return applyFunction(bigIntegerToStringNormally, value, []);
}

function normalizedAddress(address) {
    return typeof address === "string" ? address.toLowerCase() : "";
}

function validChainId(chainId) {
    return BigWalletBridgeWire.isCanonicalEthereumChainId(chainId);
}

function captureTransport(transport) {
    if (!transport || typeof transport !== "object") {
        throw new TypeError("Ethereum transport must be an object");
    }
    const isCurrent = transport.isCurrent;
    const postDisconnect = transport.postDisconnect;
    const postRequest = transport.postRequest;
    const postRPC = transport.postRPC;
    if (typeof isCurrent !== "function" ||
        typeof postDisconnect !== "function" ||
        typeof postRequest !== "function" ||
        typeof postRPC !== "function") {
        throw new TypeError("Ethereum transport is incomplete");
    }
    return freezeObjectNormally({
        isCurrent: () => applyFunction(isCurrent, transport, []),
        postDisconnect: message => applyFunction(
            postDisconnect,
            transport,
            [message]
        ),
        postRequest: message => applyFunction(
            postRequest,
            transport,
            [message]
        ),
        postRPC: (message, generation) => applyFunction(
            postRPC,
            transport,
            [message, generation]
        ),
    });
}

function transportIsCurrent(state) {
    try {
        return state.transport.isCurrent() === true;
    } catch {
        return false;
    }
}

function emitSafely(provider, eventName, values, isCurrent = null) {
    let listeners;
    try {
        listeners = applyFunction(rawListenersNormally, provider, [eventName]);
    } catch (error) {
        reportListenerError(error);
        return false;
    }
    for (let index = 0; index < listeners.length; index += 1) {
        if (typeof isCurrent === "function" && !isCurrent()) { break; }
        try {
            applyFunction(listeners[index], provider, values);
        } catch (error) {
            reportListenerError(error);
        }
    }
    return listeners.length > 0;
}

function directConnectListenerIndex(listeners, listener) {
    for (let index = listeners.length - 1;
        index >= 0;
        index -= 1) {
        if (listeners[index] === listener) { return index; }
    }
    return -1;
}

function reconcileDirectConnectListeners(provider, state, rawListeners = null) {
    const current = rawListeners || applyFunction(
        rawListenersNormally,
        provider,
        ["connect"]
    );
    const remaining = [];
    const active = [];
    for (let index = 0; index < state.directConnectListeners.length; index += 1) {
        applyFunction(pushArrayNormally, remaining, [
            state.directConnectListeners[index],
        ]);
    }
    for (let index = 0; index < current.length; index += 1) {
        const trackedIndex = directConnectListenerIndex(remaining, current[index]);
        if (trackedIndex === -1) { continue; }
        applyFunction(pushArrayNormally, active, [current[index]]);
        applyFunction(spliceArrayNormally, remaining, [trackedIndex, 1]);
    }
    state.directConnectListeners = active;
    return active;
}

function isDirectConnectListener(listeners, listener) {
    return directConnectListenerIndex(
        listeners,
        listener
    ) !== -1;
}

function addDirectListener(provider, method, eventName, listener, prepend) {
    const state = stateFor(provider);
    if (!state) {
        return applyFunction(method, provider, [eventName, listener]);
    }
    const result = applyFunction(method, provider, [eventName, listener]);
    if (eventName === "connect") {
        const listeners = applyFunction(
            rawListenersNormally,
            provider,
            [eventName]
        );
        const added = prepend ? listeners[0] : listeners[listeners.length - 1];
        if (typeof added === "function") {
            applyFunction(pushArrayNormally, state.directConnectListeners, [
                added,
            ]);
            scheduleSubscriptionConnect(provider);
        }
    }
    return result;
}

function removeDirectListener(provider, eventName, listener) {
    try {
        return applyFunction(eventRemoveListenerNormally, provider, [
            eventName,
            listener,
        ]);
    } finally {
        const state = stateFor(provider);
        if (state && eventName === "connect") {
            reconcileDirectConnectListeners(provider, state);
        }
    }
}

function removeAllDirectListeners(provider, arguments_) {
    try {
        return applyFunction(
            eventRemoveAllListenersNormally,
            provider,
            arguments_
        );
    } finally {
        const state = stateFor(provider);
        if (state &&
            (arguments_.length === 0 || arguments_[0] === "connect")) {
            reconcileDirectConnectListeners(provider, state);
        }
    }
}

function deliverFacadeConnect(state, payload, isCurrent) {
    const listener = state.facadeConnectListener;
    if (state.didDeliverFacadeConnect || typeof listener !== "function" ||
        !isCurrent()) {
        return false;
    }
    let delivered = false;
    try {
        delivered = applyFunction(listener, undefined, [payload]) === true;
    } catch (error) {
        reportListenerError(error);
    }
    if (delivered && isCurrent()) {
        state.didDeliverFacadeConnect = true;
        state.facadeConnectListener = null;
    }
    return delivered;
}

function emitSubscriptionConnect(provider) {
    const state = stateFor(provider);
    if (!state || !isReady(provider) || !transportIsCurrent(state)) {
        return false;
    }
    let listeners;
    try {
        listeners = applyFunction(rawListenersNormally, provider, ["connect"]);
        reconcileDirectConnectListeners(provider, state, listeners);
    } catch (error) {
        reportListenerError(error);
        return false;
    }
    const directListeners = [];
    for (let index = 0; index < state.directConnectListeners.length; index += 1) {
        applyFunction(pushArrayNormally, directListeners, [
            state.directConnectListeners[index],
        ]);
    }
    const direct = directListeners.length > 0 &&
        !state.didDeliverDirectConnect;
    const facade = typeof state.facadeConnectListener === "function" &&
        !state.didDeliverFacadeConnect;
    if (!direct && !facade) { return false; }
    state.didDeliverDirectConnect ||= direct;
    const epoch = state.stateEpoch;
    const lifecycleCurrent = () => stateFor(provider) === state &&
        !state.retired && transportIsCurrent(state);
    const current = () => lifecycleCurrent() && state.stateEpoch === epoch;
    const payload = freezeObjectNormally({chainId: state.chainId});
    if (direct) {
        for (let index = 0; index < listeners.length; index += 1) {
            if (!lifecycleCurrent()) { break; }
            const listener = listeners[index];
            if (!isDirectConnectListener(directListeners, listener)) { continue; }
            try {
                applyFunction(listener, provider, [payload]);
            } catch (error) {
                reportListenerError(error);
            }
        }
    }
    const facadeDelivered = facade && current()
        ? deliverFacadeConnect(state, payload, current)
        : false;
    return direct || facadeDelivered;
}

function scheduleSubscriptionConnect(provider) {
    const state = stateFor(provider);
    if (!state || state.retired || state.connectReplayScheduled) { return; }
    state.connectReplayScheduled = true;
    try {
        applyFunction(setTimeoutNormally, undefined, [() => {
            if (stateFor(provider) !== state) { return; }
            state.connectReplayScheduled = false;
            emitSubscriptionConnect(provider);
        }, 1]);
    } catch {
        state.connectReplayScheduled = false;
    }
}

function requestConnectReplay(provider, listener) {
    const state = stateFor(provider);
    if (!state || state.retired || typeof listener !== "function") {
        return false;
    }
    state.facadeConnectListener = listener;
    state.didDeliverFacadeConnect = false;
    scheduleSubscriptionConnect(provider);
    return true;
}

function authorizationSnapshot(state) {
    return {
        accountRevision: state.accountRevision,
        address: state.address,
    };
}

function authorizationIsCurrent(state, authorization) {
    return authorization?.accountRevision === state.accountRevision &&
        authorization.address === state.address;
}

function signingResponse(name) {
    return name === "signMessage" || name === "signPersonalMessage" ||
        name === "signTypedMessage" || name === "signTransaction";
}

function responseValue(record, result) {
    if (!record.metadata.wrapResult) { return result; }
    return {
        id: typeof record.originalId === "undefined"
            ? record.wireId
            : record.originalId,
        jsonrpc: "2.0",
        result,
    };
}

function settleResult(state, record, result) {
    return state.runtime.resolve(record, responseValue(record, result));
}

function settleError(state, record, error) {
    let normalized;
    try {
        normalized = normalizeEthereumProviderError(error);
    } catch {
        normalized = providerStateError();
    }
    return state.runtime.reject(record, normalized);
}

function normalizeRequestPayload(payload) {
    if (!payload || typeof payload !== "object") {
        throw new ProviderRpcError(-32600, "Invalid request");
    }
    const method = payload.method;
    if (typeof method !== "string" || method.length === 0) {
        throw new ProviderRpcError(-32600, "Invalid request");
    }
    const normalized = createObjectNormally(null);
    normalized.method = method;
    const paramsDescriptor = getOwnPropertyDescriptorNormally(payload, "params");
    if (paramsDescriptor) {
        const params = payload.params;
        if (typeof params !== "undefined") {
            try {
                normalized.params = outboundDataSnapshot(params);
            } catch {
                throw invalidParameters();
            }
        }
    }
    return {
        originalId: payload.id,
        payload: normalized,
    };
}

function operationMetadata(method, wrapResult) {
    return {
        authorization: null,
        dispatched: false,
        method,
        requestedChainId: null,
        responseName: null,
        wrapResult,
    };
}

function providerForOperation(provider) {
    const state = stateFor(provider);
    if (!state || state.retired || state.runtime.phase === "retired") {
        throw providerReplacementError();
    }
    if (!transportIsCurrent(state)) {
        retire(provider, providerReplacementError());
        throw providerReplacementError();
    }
    if (state.configurationError) { throw providerStateError(); }
    return state;
}

function registerOperation(provider, payload, wrapResult) {
    let normalized;
    let state;
    try {
        state = providerForOperation(provider);
        normalized = normalizeRequestPayload(payload);
    } catch (error) {
        return Promise.reject(error);
    }
    if (state !== stateFor(provider) || state.retired) {
        return Promise.reject(providerReplacementError());
    }
    if (!transportIsCurrent(state)) {
        const error = providerReplacementError();
        retire(provider, error);
        return Promise.reject(error);
    }
    if (state.configurationError) {
        return Promise.reject(providerStateError());
    }
    let record;
    try {
        record = state.runtime.register({
            metadata: operationMetadata(
                normalized.payload.method,
                wrapResult
            ),
            originalId: normalized.originalId,
            payload: normalized.payload,
        });
    } catch (error) {
        return Promise.reject(error);
    }
    if (state.runtime.phase === "ready") {
        dispatchSafely(provider, record);
    } else if (!state.runtime.enqueue(record)) {
        state.runtime.reject(record, providerReplacementError());
    }
    return record.promise;
}

function paramsFor(record) {
    return isArrayNormally(record.payload.params)
        ? record.payload.params
        : [];
}

function requireParameter(params, index) {
    if (!hasOwnProperty(params, index)) { throw invalidParameters(); }
    return params[index];
}

function localAccounts(state) {
    return state.address ? [state.address] : [];
}

function validAccountResult(value) {
    if (!isArrayNormally(value)) { return false; }
    for (let index = 0; index < value.length; index += 1) {
        if (!hasOwnProperty(value, index) || typeof value[index] !== "string") {
            return false;
        }
    }
    return true;
}

function setDispatchAuthorization(state, record) {
    record.metadata.authorization = authorizationSnapshot(state);
}

function walletMessage(state, record, name, data) {
    return {
        accountRevision: state.accountRevision,
        address: state.address,
        chainId: state.chainId,
        data: outboundDataSnapshot(data),
        generation: state.runtime.generation,
        id: record.wireId,
        kind: "request",
        name,
        provider: "ethereum",
    };
}

function postWalletRequest(provider, state, record, name, data) {
    setDispatchAuthorization(state, record);
    record.metadata.responseName = name;
    const message = walletMessage(state, record, name, data);
    if (!state.runtime.owns(record)) { return false; }
    if (!transportIsCurrent(state)) {
        retire(provider, providerReplacementError());
        return false;
    }
    let posted;
    try {
        record.metadata.dispatched = true;
        posted = state.transport.postRequest(message);
    } catch (error) {
        state.runtime.reject(record, error);
        return false;
    }
    if (posted === false) {
        retire(provider, providerReplacementError());
        return false;
    }
    return true;
}

function validPermissions(params) {
    if (params.length !== 1 || !params[0] ||
        typeof params[0] !== "object" || isArrayNormally(params[0])) {
        return false;
    }
    const keys = objectKeysNormally(params[0]);
    return keys.length === 1 && keys[0] === "eth_accounts" &&
        !!params[0].eth_accounts &&
        typeof params[0].eth_accounts === "object" &&
        !isArrayNormally(params[0].eth_accounts);
}

function postPermissionRevocation(provider, state, record) {
    const params = paramsFor(record);
    if (!validPermissions(params)) { throw invalidParameters(); }
    setDispatchAuthorization(state, record);
    record.metadata.responseName = "revokePermissions";
    const message = {
        accountRevision: state.accountRevision,
        address: state.address,
        generation: state.runtime.generation,
        id: record.wireId,
        kind: "disconnect",
        provider: "ethereum",
    };
    if (!state.runtime.owns(record)) { return false; }
    if (!transportIsCurrent(state)) {
        retire(provider, providerReplacementError());
        return false;
    }
    let posted;
    try {
        record.metadata.dispatched = true;
        posted = state.transport.postDisconnect(message);
    } catch (error) {
        state.runtime.reject(record, error);
        return false;
    }
    if (posted === false) {
        retire(provider, providerReplacementError());
        return false;
    }
    return true;
}

function dispatchRPC(provider, state, record) {
    setDispatchAuthorization(state, record);
    record.metadata.responseName = null;
    const payload = createObjectNormally(null);
    payload.id = record.wireId;
    payload.method = record.payload.method;
    if (hasOwnProperty(record.payload, "params")) {
        payload.params = record.payload.params;
    }
    const server = state.rpc;
    record.metadata.dispatched = true;
    const dispatched = server.call(payload, () => {
        return stateFor(provider) === state && !state.retired &&
            state.rpc === server && state.runtime.owns(record) &&
            transportIsCurrent(state);
    });
    if (!dispatched && state.runtime.owns(record)) {
        if (!transportIsCurrent(state)) {
            retire(provider, providerReplacementError());
        } else {
            state.runtime.reject(record, providerStateError());
        }
    }
    return dispatched;
}

function dispatchOperation(provider, record) {
    const state = stateFor(provider);
    if (!state || state.retired || !state.runtime.owns(record)) { return false; }
    if (!transportIsCurrent(state)) {
        retire(provider, providerReplacementError());
        return false;
    }
    const method = record.payload.method;
    const params = paramsFor(record);
    switch (method) {
        case "eth_accounts":
            return settleResult(state, record, localAccounts(state));
        case "eth_coinbase":
            return settleResult(state, record, state.address);
        case "net_version":
            return settleResult(state, record, state.networkVersion);
        case "eth_chainId":
            return settleResult(state, record, state.chainId);
        case "wallet_requestPermissions":
        case "wallet_getPermissions":
            return settleResult(state, record, [{
                parentCapability: "eth_accounts",
            }]);
        case "eth_requestAccounts":
            return state.address
                ? settleResult(state, record, localAccounts(state))
                : postWalletRequest(
                    provider,
                    state,
                    record,
                    "requestAccounts",
                    {}
                );
        case "eth_sign": {
            const buffer = Utils.messageToBuffer(requireParameter(params, 1));
            const hex = Utils.bufferToHex(buffer);
            return postWalletRequest(
                provider,
                state,
                record,
                isUtf8(buffer) ? "signPersonalMessage" : "signMessage",
                {data: hex}
            );
        }
        case "personal_sign": {
            const message = requireParameter(params, 0);
            const buffer = Utils.messageToBuffer(message);
            return postWalletRequest(
                provider,
                state,
                record,
                "signPersonalMessage",
                {data: buffer.length === 0 ? Utils.bufferToHex(message) : message}
            );
        }
        case "personal_ecRecover":
            return postWalletRequest(provider, state, record, "ecRecover", {
                message: requireParameter(params, 0),
                signature: requireParameter(params, 1),
            });
        case "eth_signTypedData_v3":
        case "eth_signTypedData":
        case "eth_signTypedData_v4":
            return postWalletRequest(
                provider,
                state,
                record,
                "signTypedMessage",
                {raw: requireParameter(params, 1)}
            );
        case "eth_sendTransaction": {
            const transaction = requireParameter(params, 0);
            if (!transaction || typeof transaction !== "object" ||
                isArrayNormally(transaction)) {
                throw invalidParameters();
            }
            return postWalletRequest(
                provider,
                state,
                record,
                "signTransaction",
                transaction
            );
        }
        case "wallet_switchEthereumChain": {
            const request = requireParameter(params, 0);
            if (!request || typeof request !== "object" ||
                !validChainId(request.chainId)) {
                throw invalidParameters();
            }
            if (request.chainId === state.chainId) {
                return settleResult(state, record, localAccounts(state));
            }
            record.metadata.requestedChainId = request.chainId;
            return postWalletRequest(
                provider,
                state,
                record,
                "switchEthereumChain",
                request
            );
        }
        case "wallet_addEthereumChain": {
            const request = requireParameter(params, 0);
            if (!request || typeof request !== "object" ||
                !validChainId(request.chainId)) {
                throw invalidParameters();
            }
            record.metadata.requestedChainId = request.chainId;
            return postWalletRequest(
                provider,
                state,
                record,
                "addEthereumChain",
                request
            );
        }
        case "wallet_revokePermissions":
            return postPermissionRevocation(provider, state, record);
        case "eth_newFilter":
        case "eth_newBlockFilter":
        case "eth_newPendingTransactionFilter":
        case "eth_uninstallFilter":
        case "eth_subscribe":
        case "eth_unsubscribe":
            throw new ProviderRpcError(
                4200,
                `Big Wallet does not support ${method}`
            );
        default:
            return dispatchRPC(provider, state, record);
    }
}

function dispatchSafely(provider, record) {
    const state = stateFor(provider);
    if (!state || !state.runtime.owns(record)) { return false; }
    try {
        return dispatchOperation(provider, record);
    } catch (error) {
        state.runtime.reject(record, error);
        return false;
    }
}

function createRPCServer(state) {
    return new RPCServer(
        state.chainId,
        state.runtime.generation,
        (message, generation) => {
            const posted = state.transport.postRPC(message, generation);
            if (posted === false) {
                retire(state.provider, providerReplacementError());
                return false;
            }
            return posted;
        }
    );
}

function commitAccount(state, address, forceRevision = false) {
    const nextAddress = normalizedAddress(address);
    const changed = state.address !== nextAddress;
    if (changed || forceRevision) { state.accountRevision += 1; }
    state.address = nextAddress;
    return changed;
}

function commitChain(state, chainId) {
    if (state.chainId === chainId) { return false; }
    state.chainId = chainId;
    state.networkVersion = normalizedNetworkVersion(chainId);
    state.rpc = createRPCServer(state);
    return true;
}

function revokeAccount(state) {
    state.accountRevocationTombstone = true;
    return commitAccount(state, "", true);
}

function flushConfigurationEvents(provider) {
    const state = stateFor(provider);
    const pending = state?.pendingConfigurationEvent;
    if (!state || !pending || state.runtime.phase !== "ready" ||
        state.retired || pending.epoch !== state.stateEpoch) {
        return;
    }
    state.pendingConfigurationEvent = null;
    state.copiedStateBaseline = null;
    const current = () => {
        const latest = stateFor(provider);
        return latest === state && !state.retired &&
            state.stateEpoch === pending.epoch;
    };
    const lifecycleCurrent = () => stateFor(provider) === state &&
        !state.retired && transportIsCurrent(state);
    if (pending.accountsChanged && current()) {
        emitSafely(provider, "accountsChanged", [localAccounts(state)], current);
    }
    if (pending.chainChanged && current()) {
        emitSafely(provider, "chainChanged", [state.chainId], current);
        if (current()) {
            emitSafely(
                provider,
                "networkChanged",
                [state.networkVersion],
                current
            );
        }
    }
    if (pending.connect && current()) {
        state.didEmitConnect = true;
        try {
            reconcileDirectConnectListeners(provider, state);
        } catch (error) {
            reportListenerError(error);
        }
        state.didDeliverDirectConnect ||=
            state.directConnectListeners.length > 0;
        const payload = freezeObjectNormally({chainId: state.chainId});
        emitSafely(
            provider,
            "connect",
            [payload],
            lifecycleCurrent
        );
        deliverFacadeConnect(
            state,
            payload,
            () => current() && transportIsCurrent(state)
        );
    }
}

function applyConfiguration(provider, envelope) {
    const state = stateFor(provider);
    if (!state || state.retired) { return false; }
    if (dataProperty(envelope, "suppressUpdate") === true) {
        return state.runtime.phase === "ready";
    }
    const epoch = state.stateEpoch + 1;
    state.stateEpoch = epoch;
    let configuration;
    try {
        configuration = outboundDataSnapshot(
            dataProperty(envelope, "configuration")
        );
    } catch {
        if (state.stateEpoch === epoch) {
            state.configurationError = true;
            state.pendingConfigurationEvent = null;
            state.runtime.rejectAll(providerStateError());
        }
        return false;
    }
    const address = configuration?.address;
    const chainId = configuration?.chainId;
    if (typeof address !== "string" || !validChainId(chainId)) {
        if (state.stateEpoch === epoch) {
            state.configurationError = true;
            state.pendingConfigurationEvent = null;
            state.runtime.rejectAll(providerStateError());
        }
        return false;
    }
    if (state.stateEpoch !== epoch || state.retired) { return false; }
    const reauthorizationRevision = configuration.reauthorizationRevision;
    const hasReauthorization = isSafeIntegerNormally(reauthorizationRevision) &&
        reauthorizationRevision >= 0;
    const switchAccount = hasReauthorization
        ? reauthorizationRevision > state.reauthorizationRevision
        : dataProperty(envelope, "switchAccount") === true;
    if (hasReauthorization) {
        state.reauthorizationRevision = Math.max(
            state.reauthorizationRevision,
            reauthorizationRevision
        );
    }
    const wasReady = state.runtime.phase === "ready";
    const copiedStateBaseline = state.copiedStateBaseline;
    let accountsChanged = false;
    let chainChanged = false;
    if (switchAccount && normalizedAddress(address)) {
        state.accountRevocationTombstone = false;
    }
    const configuredAddress = state.accountRevocationTombstone
        ? ""
        : address;
    accountsChanged = commitAccount(
        state,
        configuredAddress,
        switchAccount
    );
    chainChanged = commitChain(state, chainId);
    state.configurationError = false;
    const connect = !state.didEmitConnect;
    state.pendingConfigurationEvent = {
        accountsChanged: copiedStateBaseline
            ? state.address !== copiedStateBaseline.address
            : (wasReady || switchAccount) && accountsChanged,
        chainChanged: copiedStateBaseline
            ? state.chainId !== copiedStateBaseline.chainId
            : (wasReady || switchAccount) && chainChanged,
        connect,
        epoch,
    };
    state.runtime.drain(record => dispatchOperation(provider, record));
    flushConfigurationEvents(provider);
    scheduleSubscriptionConnect(provider);
    return true;
}

function statefulResponse(name, authorizationFailure, revokeLocally) {
    return name === "requestAccounts" ||
        name === "switchEthereumChain" ||
        name === "addEthereumChain" ||
        name === "revokePermissions" ||
        authorizationFailure || revokeLocally;
}

function responseRecord(state, envelope) {
    const id = dataProperty(envelope, "id");
    return state.runtime.operation(id);
}

function matchingResponseName(record, name) {
    if (record.metadata.responseName === null) {
        return name === null || typeof name === "undefined";
    }
    return record.metadata.responseName === name;
}

function emitResponseDeltas(provider, state, epoch, deltas) {
    const current = () => {
        return stateFor(provider) === state && !state.retired &&
            state.stateEpoch === epoch;
    };
    if (deltas.accountsChanged && current()) {
        emitSafely(provider, "accountsChanged", [localAccounts(state)], current);
    }
    if (deltas.chainChanged && current()) {
        emitSafely(provider, "chainChanged", [state.chainId], current);
        if (current()) {
            emitSafely(
                provider,
                "networkChanged",
                [state.networkVersion],
                current
            );
        }
    }
}

function applyResultEnvelope(provider, state, envelope) {
    const record = responseRecord(state, envelope);
    if (!record) { return false; }
    if (!record.metadata.dispatched) { return false; }
    const name = dataProperty(envelope, "name");
    if (!matchingResponseName(record, name)) {
        return settleError(state, record, providerStateError());
    }
    let result;
    try {
        result = nativeJSONClone(dataProperty(envelope, "result"));
    } catch {
        return settleError(state, record, providerStateError());
    }
    if (!state.runtime.owns(record)) { return false; }
    if ((name === "requestAccounts" && !validAccountResult(result)) ||
        ((name === "switchEthereumChain" ||
            name === "addEthereumChain") && result !== null &&
            !validAccountResult(result))) {
        return settleError(state, record, providerStateError());
    }
    if (signingResponse(name) && envelope.approvalCommitted !== true &&
        !authorizationIsCurrent(state, record.metadata.authorization)) {
        return settleError(state, record, authorizationChangedError());
    }
    if (name === "requestAccounts" &&
        dataProperty(envelope, "configurationApplied") === false) {
        return settleResult(
            state,
            record,
            envelope.approvalCommitted === true ? result : []
        );
    }
    const changesState = dataProperty(envelope, "suppressUpdate") !== true &&
        statefulResponse(name, false, false);
    const epoch = changesState ? state.stateEpoch + 1 : null;
    if (changesState) { state.stateEpoch = epoch; }
    const deltas = {accountsChanged: false, chainChanged: false};
    let settlementResult = result;
    if (changesState && state.stateEpoch === epoch) {
        if (name === "requestAccounts") {
            const address = isArrayNormally(result) &&
                typeof result[0] === "string"
                ? result[0]
                : "";
            const currentAuthorization = authorizationIsCurrent(
                state,
                record.metadata.authorization
            );
            const appliedConfigurationMatches =
                dataProperty(envelope, "configurationApplied") === true &&
                normalizedAddress(state.address) === normalizedAddress(address);
            if (currentAuthorization || appliedConfigurationMatches) {
                if (address) {
                    state.accountRevocationTombstone = false;
                }
                deltas.accountsChanged = commitAccount(
                    state,
                    address,
                    !appliedConfigurationMatches
                );
            } else if (envelope.approvalCommitted !== true) {
                settlementResult = [];
            }
        } else if (name === "switchEthereumChain" ||
            name === "addEthereumChain") {
            const shouldApplyChain = envelope.approvalCommitted !== true ||
                dataProperty(envelope, "configurationApplied") === true;
            if (shouldApplyChain &&
                validChainId(record.metadata.requestedChainId)) {
                deltas.chainChanged = commitChain(
                    state,
                    record.metadata.requestedChainId
                );
            }
            if (record.metadata.authorization?.address &&
                authorizationIsCurrent(
                    state,
                    record.metadata.authorization
                ) &&
                isArrayNormally(result) &&
                (result.length === 0 || typeof result[0] === "string")) {
                deltas.accountsChanged = commitAccount(
                    state,
                    typeof result[0] === "string" ? result[0] : ""
                );
            }
        } else if (name === "revokePermissions" && authorizationIsCurrent(
            state,
            record.metadata.authorization
        )) {
            deltas.accountsChanged = revokeAccount(state);
        }
    }
    const settled = settleResult(state, record, settlementResult);
    if (changesState && settled) {
        emitResponseDeltas(provider, state, epoch, deltas);
    }
    return settled;
}

function applyErrorEnvelope(provider, state, envelope) {
    const record = responseRecord(state, envelope);
    if (!record) { return false; }
    if (!record.metadata.dispatched) { return false; }
    const name = dataProperty(envelope, "name");
    if (!matchingResponseName(record, name)) {
        return settleError(state, record, providerStateError());
    }
    const authorizationFailure =
        dataProperty(envelope, "authorizationFailure") === true;
    const revokeLocally = dataProperty(envelope, "revokeLocally") === true;
    const changesState = dataProperty(envelope, "suppressUpdate") !== true &&
        statefulResponse(name, authorizationFailure, revokeLocally);
    const epoch = changesState ? state.stateEpoch + 1 : null;
    if (changesState) { state.stateEpoch = epoch; }
    const error = dataProperty(envelope, "error");
    if (!state.runtime.owns(record)) { return false; }
    const deltas = {accountsChanged: false, chainChanged: false};
    if (changesState && state.stateEpoch === epoch) {
        let didRevoke = false;
        if (authorizationFailure && authorizationIsCurrent(
            state,
            record.metadata.authorization
        )) {
            deltas.accountsChanged = revokeAccount(state);
            didRevoke = true;
        }
        if (name === "revokePermissions" && revokeLocally && !didRevoke &&
            authorizationIsCurrent(state, record.metadata.authorization)) {
            deltas.accountsChanged = revokeAccount(state) ||
                deltas.accountsChanged;
        }
    }
    const settled = settleError(state, record, error);
    if (changesState && settled) {
        emitResponseDeltas(provider, state, epoch, deltas);
    }
    return settled;
}

function applyEnvelope(provider, envelope) {
    const state = stateFor(provider);
    if (!state || state.retired || !envelope ||
        typeof envelope !== "object") {
        return false;
    }
    if (!transportIsCurrent(state)) {
        retire(provider, providerReplacementError());
        return false;
    }
    const kind = dataProperty(envelope, "kind");
    if (kind === "configuration") {
        return applyConfiguration(provider, envelope);
    }
    if (kind === "configurationError") {
        const error = normalizeEthereumProviderError(dataProperty(envelope, "error"));
        if (!state.runtime.failLoading(error)) { return false; }
        state.stateEpoch += 1;
        state.pendingConfigurationEvent = null;
        state.didEmitConnect = false;
        state.didDeliverDirectConnect = false;
        state.didDeliverFacadeConnect = false;
        emitSafely(provider, "disconnect", [error]);
        return true;
    }
    if (kind === "result") {
        return applyResultEnvelope(provider, state, envelope);
    }
    if (kind === "error") {
        return applyErrorEnvelope(provider, state, envelope);
    }
    return false;
}

function retire(provider, error = providerReplacementError()) {
    const state = stateFor(provider);
    if (!state || state.retired) { return false; }
    state.retired = true;
    state.stateEpoch += 1;
    state.pendingConfigurationEvent = null;
    const hadAccount = state.address.length > 0;
    state.address = "";
    state.accountRevision += 1;
    state.runtime.retire(error);
    emitSafely(provider, "disconnect", [error]);
    if (hadAccount) { emitSafely(provider, "accountsChanged", [[]]); }
    return true;
}

function snapshot(provider) {
    const state = stateFor(provider);
    if (!state) { return null; }
    return freezeObjectNormally({
        accountRevision: state.accountRevision,
        accountRevocationTombstone: state.accountRevocationTombstone,
        reauthorizationRevision: state.reauthorizationRevision,
        address: state.address,
        chainId: state.chainId,
        didEmitConnect: state.didEmitConnect,
        generation: state.runtime.generation,
        isConnected: !state.retired && state.runtime.phase !== "failed",
        phase: state.runtime.phase,
        ready: isReady(provider),
    });
}

function isReady(provider) {
    const state = stateFor(provider);
    return !!state && !state.retired && !state.configurationError &&
        state.runtime.phase === "ready";
}

const metamaskAPI = freezeObjectNormally({
    isUnlocked() {
        return Promise.resolve(true);
    },
});

class BigWalletEthereum extends EventEmitter {

    constructor(providerGeneration, transport, initialState = null) {
        super();
        const capturedTransport = captureTransport(transport);
        let initial = null;
        if (initialState !== null) {
            initial = outboundDataSnapshot(initialState);
        }
        const copiedInitialState = !!initial &&
            typeof initial.address === "string" &&
            validChainId(initial.chainId) &&
            isSafeIntegerNormally(initial.accountRevision) &&
            initial.accountRevision >= 0 &&
            typeof initial.accountRevocationTombstone === "boolean" &&
            typeof initial.didEmitConnect === "boolean";
        const chainId = validChainId(initial?.chainId)
            ? initial.chainId
            : "0x1";
        const state = {
            accountRevision:
                isSafeIntegerNormally(initial?.accountRevision) &&
                initial.accountRevision >= 0
                    ? initial.accountRevision
                    : 0,
            accountRevocationTombstone:
                initial?.accountRevocationTombstone === true,
            reauthorizationRevision:
                isSafeIntegerNormally(initial?.reauthorizationRevision) &&
                initial.reauthorizationRevision >= 0
                    ? initial.reauthorizationRevision
                    : 0,
            address: normalizedAddress(initial?.address),
            chainId,
            configurationError: false,
            connectReplayScheduled: false,
            copiedStateBaseline: null,
            didDeliverDirectConnect: false,
            didDeliverFacadeConnect: false,
            didEmitConnect: initial?.didEmitConnect === true,
            directConnectListeners: [],
            facadeConnectListener: null,
            initialized: true,
            networkVersion: normalizedNetworkVersion(chainId),
            pendingConfigurationEvent: null,
            provider: this,
            retired: false,
            rpc: null,
            runtime: new OperationRuntime(providerGeneration, {
                firstWireId: 1,
                wireIdStep: 2,
            }),
            stateEpoch: 0,
            transport: capturedTransport,
        };
        if (state.accountRevocationTombstone) { state.address = ""; }
        if (copiedInitialState) {
            state.copiedStateBaseline = {
                address: state.address,
                chainId: state.chainId,
            };
        }
        applyFunction(setWeakMapValueNormally, providerStates, [this, state]);
        state.rpc = createRPCServer(state);
        try {
            applyFunction(setTimeoutNormally, undefined, [() => {
                if (!state.retired) { emitSafely(this, "_initialized", []); }
            }, 1]);
        } catch {
        }
    }

    get _initialized() { return true; }
    get _isConnected() { return this.isConnected(); }
    get _isUnlocked() { return true; }
    get _metamask() { return metamaskAPI; }
    get address() { return stateFor(this)?.address || ""; }
    get chainId() { return stateFor(this)?.chainId || "0x1"; }
    get isBigWallet() { return true; }
    get isMetaMask() { return true; }
    get networkVersion() { return stateFor(this)?.networkVersion || null; }
    get ready() { return !!stateFor(this)?.address; }
    get selectedAddress() { return stateFor(this)?.address || null; }

    addListener(eventName, listener) {
        return addDirectListener(
            this,
            eventAddListenerNormally,
            eventName,
            listener,
            false
        );
    }

    on(eventName, listener) {
        return addDirectListener(
            this,
            eventOnNormally,
            eventName,
            listener,
            false
        );
    }

    prependListener(eventName, listener) {
        return addDirectListener(
            this,
            eventPrependListenerNormally,
            eventName,
            listener,
            true
        );
    }

    removeListener(eventName, listener) {
        return removeDirectListener(this, eventName, listener);
    }

    off(eventName, listener) {
        return removeDirectListener(this, eventName, listener);
    }

    removeAllListeners(...arguments_) {
        return removeAllDirectListeners(this, arguments_);
    }

    request(payload) {
        return registerOperation(this, payload, false);
    }

    send(payload, callback) {
        const requestPayload = typeof payload === "string"
            ? {method: payload}
            : payload;
        if (typeof callback === "function") {
            this.sendAsync(requestPayload, callback);
            return;
        }
        return registerOperation(this, requestPayload, false);
    }

    sendAsync(payload, callback) {
        const requests = [];
        if (isArrayNormally(payload)) {
            for (let index = 0; index < payload.length; index += 1) {
                requests[requests.length] = registerOperation(
                    this,
                    payload[index],
                    true
                );
            }
        } else {
            requests[0] = registerOperation(this, payload, true);
        }
        Promise.all(requests).then(
            results => callback(null, isArrayNormally(payload)
                ? results
                : results[0]),
            error => callback(error, null)
        );
    }

    enable() {
        return this.request({
            method: this.selectedAddress
                ? "eth_accounts"
                : "eth_requestAccounts",
            params: [],
        });
    }

    isConnected() {
        const state = stateFor(this);
        return !!state && !state.retired && state.runtime.phase !== "failed";
    }

    isUnlocked() {
        return Promise.resolve(true);
    }
}

BigWalletEthereum.applyEnvelope = applyEnvelope;
BigWalletEthereum.isReady = isReady;
BigWalletEthereum.retire = retire;
BigWalletEthereum.snapshot = snapshot;

export {
    applyEnvelope,
    isReady,
    requestConnectReplay,
    retire,
    snapshot,
};
export default BigWalletEthereum;
