// Copyright © 2021 Encrypted Ink. All rights reserved.
// Rewrite of index.js from trust-web3-provider.

"use strict";

import RPCServer from "./rpc";
import ProviderRpcError from "./error";
import Utils from "./utils";
import IdMapping from "./id_mapping";
import { EventEmitter } from "events";
import isUtf8 from "isutf8";

class TokenaryWeb3Provider extends EventEmitter {
    constructor(config) {
        super();
        this.setConfig(config);
        this.idMapping = new IdMapping();
        this.callbacks = new Map();
        this.wrapResults = new Map();
        this.isMetaMask = true;
        this.isTokenary = true;
        this.emitConnect(config.chainId);
    }
    
    setAddress(address) {
        const lowerAddress = (address || "").toLowerCase();
        this.address = lowerAddress;
        this.ready = !!address;
    }
    
    updateAccount(eventName, addresses, chainId, rpcUrl) {
        window.ethereum.setAddress(addresses[0]);
        
        if (eventName == "switchAccount") {
            window.ethereum.emit("accountsChanged", addresses);
        }
        
        if (window.ethereum.rpc.rpcUrl != rpcUrl) {
            this.rpc = new RPCServer(rpcUrl);
        }
        
        if (window.ethereum.chainId != chainId) {
            window.ethereum.chainId = chainId;
            window.ethereum.emit("chainChanged", chainId);
            window.ethereum.emit("networkChanged", window.ethereum.net_version());
        }
    }
    
    setConfig(config) {
        this.chainId = config.chainId;
        this.rpc = new RPCServer(config.rpcUrl);
        this.setAddress("");
    }
    
    request(payload) {
        // this points to window in methods like web3.eth.getAccounts()
        var that = this;
        if (!(this instanceof TokenaryWeb3Provider)) {
            that = window.ethereum;
        }
        return that._request(payload, false);
    }
    
    /**
     * @deprecated Listen to "connect" event instead.
     */
    isConnected() {
        return true;
    }
    
    /**
     * @deprecated Use request({method: "eth_requestAccounts"}) instead.
     */
    enable() {
        console.log('enable() is deprecated, please use window.ethereum.request({method: "eth_requestAccounts"}) instead.');
        if (!window.ethereum.address) { // avoid double accounts request in uniswap
            return this.request({ method: "eth_requestAccounts", params: [] });
        } else {
            return this.request({ method: "eth_accounts", params: [] });
        }
    }
    
    /**
     * @deprecated Use request() method instead.
     */
    send(payload) {
        let response = { jsonrpc: "2.0", id: payload.id };
        switch (payload.method) {
            case "eth_accounts":
                response.result = this.eth_accounts();
                break;
            case "eth_coinbase":
                response.result = this.eth_coinbase();
                break;
            case "net_version":
                response.result = this.net_version();
                break;
            case "eth_chainId":
                response.result = this.eth_chainId();
                break;
            default:
                throw new ProviderRpcError(4200, `Tokenary does not support calling ${payload.method} synchronously without a callback. Please provide a callback parameter to call ${payload.method} asynchronously.`);
        }
        return response;
    }
    
    /**
     * @deprecated Use request() method instead.
     */
    sendAsync(payload, callback) {
        console.log("sendAsync(data, callback) is deprecated, please use window.ethereum.request(data) instead.");
        // this points to window in methods like web3.eth.getAccounts()
        var that = this;
        if (!(this instanceof TokenaryWeb3Provider)) {
            that = window.ethereum;
        }
        if (Array.isArray(payload)) {
            Promise.all(payload.map(that._request.bind(that)))
            .then((data) => callback(null, data))
            .catch((error) => callback(error, null));
        } else {
            that
            ._request(payload)
            .then((data) => callback(null, data))
            .catch((error) => callback(error, null));
        }
    }
    
    /**
     * @private Internal rpc handler
     */
    _request(payload, wrapResult = true) {
        this.idMapping.tryIntifyId(payload);
        return new Promise((resolve, reject) => {
            if (!payload.id) {
                payload.id = Utils.genId();
            }
            this.callbacks.set(payload.id, (error, data) => {
                if (error) {
                    reject(error);
                } else {
                    resolve(data);
                }
            });
            this.wrapResults.set(payload.id, wrapResult);
            switch (payload.method) {
                case "eth_accounts":
                    return this.sendResponse(payload.id, this.eth_accounts());
                case "eth_coinbase":
                    return this.sendResponse(payload.id, this.eth_coinbase());
                case "net_version":
                    return this.sendResponse(payload.id, this.net_version());
                case "eth_chainId":
                    return this.sendResponse(payload.id, this.eth_chainId());
                case "eth_sign":
                    return this.eth_sign(payload);
                case "personal_sign":
                    return this.personal_sign(payload);
                case "personal_ecRecover":
                    return this.personal_ecRecover(payload);
                case "eth_signTypedData_v3":
                    return this.eth_signTypedData(payload, false);
                case "eth_signTypedData":
                case "eth_signTypedData_v4":
                    return this.eth_signTypedData(payload, true);
                case "eth_sendTransaction":
                    return this.eth_sendTransaction(payload);
                case "eth_requestAccounts":
                    return this.eth_requestAccounts(payload);
                case "wallet_watchAsset":
                    return this.wallet_watchAsset(payload);
                case "wallet_addEthereumChain":
                    return this.wallet_addEthereumChain(payload);
                case "wallet_switchEthereumChain":
                    return this.wallet_switchEthereumChain(payload);
                case "eth_newFilter":
                case "eth_newBlockFilter":
                case "eth_newPendingTransactionFilter":
                case "eth_uninstallFilter":
                case "eth_subscribe":
                    throw new ProviderRpcError(4200, `Tokenary does not support calling ${payload.method}. Please use your own solution`);
                default:
                    this.callbacks.delete(payload.id);
                    this.wrapResults.delete(payload.id);
                    return this.rpc
                    .call(payload)
                    .then((response) => {
                        wrapResult ? resolve(response) : resolve(response.result);
                    })
                    .catch(reject);
            }
        });
    }
    
    emitConnect(chainId) {
        this.emit("connect", { chainId: chainId });
    }
    
    eth_accounts() {
        return this.address ? [this.address] : [];
    }
    
    eth_coinbase() {
        return this.address;
    }
    
    net_version() {
        return parseInt(this.chainId, 16).toString(10) || null;
    }
    
    eth_chainId() {
        return this.chainId;
    }
    
    eth_sign(payload) {
        const buffer = Utils.messageToBuffer(payload.params[1]);
        const hex = Utils.bufferToHex(buffer);
        if (isUtf8(buffer)) {
            this.postMessage("signPersonalMessage", payload.id, { data: hex });
        } else {
            this.postMessage("signMessage", payload.id, { data: hex });
        }
    }
    
    personal_sign(payload) {
        const message = payload.params[0];
        const buffer = Utils.messageToBuffer(message);
        if (buffer.length === 0) {
            // hex it
            const hex = Utils.bufferToHex(message);
            this.postMessage("signPersonalMessage", payload.id, { data: hex });
        } else {
            this.postMessage("signPersonalMessage", payload.id, { data: message });
        }
    }
    
    personal_ecRecover(payload) {
        this.postMessage("ecRecover", payload.id, {
        signature: payload.params[1],
        message: payload.params[0],
        });
    }
    
    eth_signTypedData(payload, useV4) {
        this.postMessage("signTypedMessage", payload.id, {
        raw: payload.params[1],
        });
    }
    
    eth_sendTransaction(payload) {
        this.postMessage("signTransaction", payload.id, payload.params[0]);
    }
    
    eth_requestAccounts(payload) {
        this.postMessage("requestAccounts", payload.id, {});
    }
    
    wallet_watchAsset(payload) {
        let options = payload.params.options;
        this.postMessage("watchAsset", payload.id, {
        type: payload.type,
        contract: options.address,
        symbol: options.symbol,
        decimals: options.decimals || 0,
        });
    }
    
    wallet_switchEthereumChain(payload) {
        if (this.chainId != payload.params[0].chainId) {
            this.postMessage("switchEthereumChain", payload.id, payload.params[0]);
        }
    }
    
    wallet_addEthereumChain(payload) {
        this.postMessage("addEthereumChain", payload.id, payload.params[0]);
    }
    
    /**
     * @private Internal js -> native message handler
     */
    postMessage(handler, id, data) {
        if (this.ready || handler === "requestAccounts") {
            let object = {id: id, name: handler, object: data, address: this.address, networkId: this.net_version()};
            if (window.tokenary.postMessage) {
                window.tokenary.postMessage(object);
            } else {
                // old clients
                window.webkit.messageHandlers[handler].postMessage(object);
            }
        } else {
            // don't forget to verify in the app
            this.sendError(id, new ProviderRpcError(4100, "provider is not ready"));
        }
    }
    
    /**
     * @private Internal native result -> js
     */
    sendResponse(id, result) {
        let originId = this.idMapping.tryPopId(id) || id;
        let callback = this.callbacks.get(id);
        let wrapResult = this.wrapResults.get(id);
        let data = { jsonrpc: "2.0", id: originId };
        if (typeof result === "object" && result.jsonrpc && result.result) {
            data.result = result.result;
        } else {
            data.result = result;
        }
        if (callback) {
            wrapResult ? callback(null, data) : callback(null, result);
            this.callbacks.delete(id);
        } else {
            console.log(`callback id: ${id} not found`);
            // check if it's iframe callback
            for (var i = 0; i < window.frames.length; i++) {
                const frame = window.frames[i];
                try {
                    if (frame.ethereum.callbacks.has(id)) {
                        frame.ethereum.sendResponse(id, result);
                    }
                } catch (error) {
                    console.log(`send response to frame error: ${error}`);
                }
            }
        }
    }
    
    /**
     * @private Internal native error -> js
     */
    sendError(id, error) {
        console.log(`<== ${id} sendError ${error}`);
        let callback = this.callbacks.get(id);
        if (callback) {
            callback(error instanceof Error ? error : new Error(error), null);
            this.callbacks.delete(id);
        }
    }
}

window.tokenary = {Provider: TokenaryWeb3Provider, postMessage: null};

(function() {
    var config = {chainId: "0x1", rpcUrl: "https://mainnet.infura.io/v3/3f99b6096fda424bbb26e17866dcddfc"};
    window.ethereum = new tokenary.Provider(config);
    
    const handler = {
        get(target, property) {
            return window.ethereum;
        }
    }
    window.web3 = new Proxy(window.ethereum, handler);
    
    tokenary.postMessage = (jsonString) => {
        window.postMessage({direction: "from-page-script", message: jsonString}, "*");
    };
})();

window.addEventListener("message", function(event) {
    if (event.source == window && event.data && event.data.direction == "from-content-script") {
        const response = event.data.response;
        
        if ("result" in response) {
            window.ethereum.sendResponse(event.data.id, response.result);
        } else if ("results" in response) {
            if (response.name != "switchAccount") {
                window.ethereum.sendResponse(event.data.id, response.results);
            }
            if (response.name == "requestAccounts" || response.name == "switchAccount") {
                window.ethereum.updateAccount(response.name, response.results, response.chainId, response.rpcURL);
            }
        } else if ("error" in response) {
            window.ethereum.sendError(event.data.id, response.error);
        }
    }
});
