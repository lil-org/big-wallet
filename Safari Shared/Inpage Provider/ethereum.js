// ∅ 2026 lil org

"use strict";

import {
    applyFunction,
    createObjectNormally,
    freezeObjectNormally,
    getOwnPropertyDescriptorNormally,
    isArrayNormally,
    isSafeIntegerNormally,
    getWeakMapValue,
    setWeakMapValue,
    hasOwnProperty,
} from "./intrinsics";

import RPCServer from "./rpc";
import ProviderRpcError, {
    normalizeEthereumProviderError,
    providerReplacementError,
} from "./error";
import OperationRuntime from "./operation_runtime";
import {
    nativeJSONClone,
    outboundDataSnapshot,
    trustedOutboundRecord,
} from "./outbound_snapshot";
import Utils from "./utils";
import isUtf8 from "isutf8";
import BigWalletBridgeWire from "../Resources/bridge_wire";

const objectKeysNormally = Object.keys;
const stringStartsWithNormally = String.prototype.startsWith;
const stringToLowerCaseNormally = String.prototype.toLowerCase;
const bigIntegerNormally = BigInt;
const bigIntegerToStringNormally = BigInt.prototype.toString;
const setTimeoutNormally = setTimeout;
const providerStates = new WeakMap;
const invalidParametersMessage = "Invalid parameters";
const providerStateMessage = "Failed to update provider state";
const authorizationChangedMessage =
    "Authorization changed while the request was pending";

function stateFor(provider) {
    return getWeakMapValue(providerStates, provider);
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
    return typeof address === "string" ? applyFunction(stringToLowerCaseNormally, address, []) : "";
}

function validChainId(chainId) {
    return BigWalletBridgeWire.isCanonicalEthereumChainId(chainId);
}

function transportIsCurrent(state) {
    try {
        return state.transport.isCurrent() === true;
    } catch {
        return false;
    }
}

function emitSafely(provider, eventName, values, isCurrent = null) {
    const listener = stateFor(provider)?.notificationListener;
    if (typeof listener !== "function" || isCurrent && !isCurrent()) {
        return false;
    }
    try {
        applyFunction(listener, provider, [{kind: "event", name: eventName, args: values}]);
    } catch (error) {
        reportListenerError(error);
    }
    return true;
}

function withReadyState(provider, listener) {
    const state = stateFor(provider);
    if (!state || typeof listener !== "function" ||
        !isReady(provider) || !transportIsCurrent(state)) {
        return false;
    }
    const epoch = state.stateEpoch;
    const payload = freezeObjectNormally({chainId: state.chainId});
    if (stateFor(provider) !== state || state.retired ||
        state.stateEpoch !== epoch || !transportIsCurrent(state)) {
        return false;
    }
    try {
        return applyFunction(listener, undefined, [payload]) === true;
    } catch (error) {
        reportListenerError(error);
        return false;
    }
}

function subscribeNotifications(provider, listener) {
    const state = stateFor(provider);
    if (!state || state.retired || typeof listener !== "function") {
        return () => {};
    }
    state.notificationListener = listener;
    return () => {
        if (state.notificationListener === listener) {
            state.notificationListener = null;
        }
    };
}

function notifyReadiness(provider, flushed) {
    const state = stateFor(provider);
    const listener = state?.notificationListener;
    if (!state || state.retired || typeof listener !== "function") { return; }
    try {
        applyFunction(listener, undefined, [freezeObjectNormally({kind: "readiness", flushed})]);
    } catch (error) {
        reportListenerError(error);
    }
}

function authorizationSnapshot(state) {
    return {
        revision: state.workerRevision,
        address: state.address,
    };
}

function authorizationIsCurrent(state, authorization) {
    return authorization?.revision === state.workerRevision &&
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
    const params = payload.params;
    if (typeof params !== "undefined") {
        try {
            normalized.params = outboundDataSnapshot(params);
        } catch {
            throw invalidParameters();
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
        expectedAddress: null,
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
    return state;
}

function registerOperation(provider, payload, wrapResult) {
    let normalized;
    let state;
    let expectedAddress;
    try {
        state = providerForOperation(provider);
        expectedAddress = state.address || null;
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
    record.metadata.expectedAddress = expectedAddress;
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
    const requiresSnapshot = (name === "signPersonalMessage" &&
        typeof data.data !== "string") ||
        name === "switchEthereumChain" || name === "addEthereumChain";
    return {
        address: state.address,
        chainId: state.chainId,
        data: requiresSnapshot
            ? outboundDataSnapshot(data)
            : trustedOutboundRecord(data),
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
    if (record.metadata.expectedAddress &&
        record.metadata.expectedAddress !== state.address &&
        (method === "eth_sign" || method === "personal_sign" ||
            applyFunction(stringStartsWithNormally, method, ["eth_signTypedData"]) || method === "eth_sendTransaction")) {
        throw authorizationChangedError();
    }
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
        case "wallet_switchEthereumChain":
        case "wallet_addEthereumChain": {
            const request = requireParameter(params, 0);
            if (!request || typeof request !== "object" ||
                typeof request.chainId !== "string" ||
                !applyFunction(stringStartsWithNormally, request.chainId, ["0x"])) {
                throw invalidParameters();
            }
            request.chainId = applyFunction(
                stringToLowerCaseNormally,
                request.chainId,
                []
            );
            if (!validChainId(request.chainId)) { throw invalidParameters(); }
            const name = method === "wallet_switchEthereumChain"
                ? "switchEthereumChain"
                : "addEthereumChain";
            if (name === "switchEthereumChain" && request.chainId === state.chainId) {
                return settleResult(state, record, null);
            }
            record.metadata.requestedChainId = request.chainId;
            return postWalletRequest(
                provider,
                state,
                record,
                name,
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

function prepareConfiguration(provider, configuration, revision) {
    const state = stateFor(provider);
    if (!state || state.retired || !isSafeIntegerNormally(revision) || revision < 0) {
        return null;
    }
    const address = normalizedAddress(configuration.address);
    const chainId = configuration.chainId;
    if (!validChainId(chainId)) { return null; }
    if (state.workerRevision !== null && revision < state.workerRevision) {
        return {__proto__: null, ignored: true};
    }
    if (revision === state.workerRevision &&
        (address !== state.address || chainId !== state.chainId)) {
        return null;
    }
    return {
        __proto__: null,
        address, chainId, revision, baseline: state.stateEpoch,
        networkVersion: normalizedNetworkVersion(chainId),
        rpc: state.chainId === chainId ? state.rpc : new RPCServer(
            chainId, state.runtime.generation,
            (message, generation) => {
                const posted = state.transport.postRPC(message, generation);
                if (posted === false) { retire(provider, providerReplacementError()); }
                return posted;
            }
        ),
    };
}

function configurationIsCurrent(provider, prepared) {
    const state = stateFor(provider);
    return !!state && !state.retired && (!prepared || prepared.ignored || prepared.baseline === state.stateEpoch);
}

function commitConfiguration(provider, prepared) {
    const state = stateFor(provider);
    if (!state || state.retired || !prepared || prepared.ignored) { return null; }
    const wasReady = state.runtime.phase === "ready";
    const accountsChanged = state.address !== prepared.address;
    const chainChanged = state.chainId !== prepared.chainId;
    state.address = prepared.address;
    state.chainId = prepared.chainId;
    state.networkVersion = prepared.networkVersion;
    state.rpc = prepared.rpc;
    if (state.workerRevision !== prepared.revision) { state.stateEpoch += 1; }
    state.workerRevision = prepared.revision;
    state.runtime.activate();
    return {
        epoch: state.stateEpoch,
        accountsChanged: (wasReady || state.copiedStateBaseline !== null) && accountsChanged,
        chainChanged: (wasReady || state.copiedStateBaseline !== null) && chainChanged,
    };
}

function emitConfiguration(provider, change) {
    const state = stateFor(provider);
    if (!state || !change) { return; }
    const current = () => stateFor(provider) === state && !state.retired &&
        state.stateEpoch === change.epoch && transportIsCurrent(state);
    if (change.accountsChanged && current()) {
        emitSafely(provider, "accountsChanged", [localAccounts(state)], current);
    }
    if (change.chainChanged && current()) {
        emitSafely(provider, "chainChanged", [state.chainId], current);
        if (current()) {
            emitSafely(provider, "networkChanged", [state.networkVersion], current);
        }
    }
}

function finishConfiguration(provider, change) {
    const state = stateFor(provider);
    if (!state || !change || state.retired || state.stateEpoch !== change.epoch) { return; }
    state.copiedStateBaseline = null;
    state.runtime.drain(record => dispatchOperation(provider, record));
    if (state.stateEpoch === change.epoch && !state.retired) {
        notifyReadiness(provider, true);
    }
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

function applyResultEnvelope(provider, state, envelope) {
    const record = responseRecord(state, envelope);
    if (!record || !record.metadata.dispatched) { return false; }
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
    if (name === "requestAccounts" && !validAccountResult(result) ||
        (name === "switchEthereumChain" || name === "addEthereumChain") && result !== null) {
        return settleError(state, record, providerStateError());
    }
    if (envelope.approvalCommitted !== true && (
        signingResponse(name) && !authorizationIsCurrent(state, record.metadata.authorization) ||
        name === "requestAccounts" && (normalizedAddress(result[0]) !== state.address ||
            (envelope.state ? envelope.state.revisions.ethereum !== state.workerRevision :
                !authorizationIsCurrent(state, record.metadata.authorization)))
    )) {
        return settleError(state, record, authorizationChangedError());
    }
    return settleResult(state, record,
        name === "switchEthereumChain" || name === "addEthereumChain" ? null : result);
}

function applyErrorEnvelope(provider, state, envelope) {
    const record = responseRecord(state, envelope);
    if (!record || !record.metadata.dispatched) { return false; }
    const name = dataProperty(envelope, "name");
    return settleError(state, record, matchingResponseName(record, name)
        ? dataProperty(envelope, "error") : providerStateError());
}

function applyDecodedEnvelope(provider, envelope) {
    const state = stateFor(provider);
    if (!state || state.retired) {
        return false;
    }
    if (!transportIsCurrent(state)) {
        retire(provider, providerReplacementError());
        return false;
    }
    const kind = dataProperty(envelope, "kind");
    if (kind === "configuration") {
        const prepared = prepareConfiguration(provider, envelope.configuration, envelope.workerRevision);
        if (!prepared || !configurationIsCurrent(provider, prepared)) { return false; }
        const change = commitConfiguration(provider, prepared);
        emitConfiguration(provider, change);
        finishConfiguration(provider, change);
        return true;
    }
    if (kind === "configurationError") {
        const error = normalizeEthereumProviderError(dataProperty(envelope, "error"));
        if (!state.runtime.failLoading(error)) { return false; }
        state.stateEpoch += 1;
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
    const hadAccount = state.address.length > 0;
    state.address = "";
    state.runtime.retire(error);
    emitSafely(provider, "disconnect", [error]);
    if (hadAccount) { emitSafely(provider, "accountsChanged", [[]]); }
    state.notificationListener = null;
    return true;
}

function snapshot(provider) {
    const state = stateFor(provider);
    if (!state) { return null; }
    return freezeObjectNormally({
        workerRevision: state.workerRevision,
        address: state.address,
        chainId: state.chainId,
        generation: state.runtime.generation,
        isConnected: !state.retired && state.runtime.phase !== "failed",
        phase: state.runtime.phase,
        ready: isReady(provider),
    });
}

function isReady(provider) {
    const state = stateFor(provider);
    return !!state && !state.retired &&
        state.runtime.phase === "ready";
}

const metamaskAPI = freezeObjectNormally({
    isUnlocked() {
        return Promise.resolve(true);
    },
});

class BigWalletEthereum {

    constructor(providerGeneration, transport, initialState = null) {
        let initial = null;
        if (initialState !== null) {
            initial = outboundDataSnapshot(initialState);
        }
        const copiedInitialState = !!initial &&
            typeof initial.address === "string" &&
            validChainId(initial.chainId);
        const chainId = validChainId(initial?.chainId)
            ? initial.chainId
            : "0x1";
        const state = {
            workerRevision: null,
            address: normalizedAddress(initial?.address),
            chainId,
            copiedStateBaseline: null,
            notificationListener: null,
            initialized: true,
            networkVersion: normalizedNetworkVersion(chainId),
            provider: this,
            retired: false,
            rpc: null,
            runtime: new OperationRuntime(providerGeneration, {
                firstWireId: 1,
                wireIdStep: 2,
            }),
            stateEpoch: 0,
            transport,
        };
        if (copiedInitialState) {
            state.copiedStateBaseline = {
                address: state.address,
                chainId: state.chainId,
            };
        }
        setWeakMapValue(providerStates, this, state);
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

    request(payload) {
        return registerOperation(this, payload, false);
    }

    send(payload, callback) {
        const requestPayload = typeof payload === "string"
            ? {__proto__: null, method: payload}
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

BigWalletEthereum.isReady = isReady;
BigWalletEthereum.retire = retire;
BigWalletEthereum.snapshot = snapshot;

export {
    applyDecodedEnvelope,
    prepareConfiguration,
    configurationIsCurrent,
    commitConfiguration,
    emitConfiguration,
    finishConfiguration,
    isReady,
    subscribeNotifications,
    withReadyState,
    retire,
    snapshot,
};
export default BigWalletEthereum;
