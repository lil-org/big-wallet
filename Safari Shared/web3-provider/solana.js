// Copyright © 2022 Tokenary. All rights reserved.

"use strict";

import RPCServer from "./rpc";
import ProviderRpcError from "./error";
import Utils from "./utils";
import IdMapping from "./id_mapping";
import { EventEmitter } from "events";
import isUtf8 from "isutf8";
import { PublicKey, Transaction } from "@solana/web3.js";

class TokenarySolana extends EventEmitter {
    
    constructor() {
        super();

        this.idMapping = new IdMapping();
        this.callbacks = new Map();
        this.wrapResults = new Map();
        
        this.isPhantom = true;
        this.publicKey = new PublicKey("26qv4GCcx98RihuK3c4T6ozB3J7L6VwCuFVc7Ta2A3Uo"); // should be null initially
        this.isConnected = false;
        this.isTokenary = true;
        this.emitConnect();
        
        this.didGetLatestConfiguration = false;
        this.pendingPayloads = [];
        
        const originalOn = this.on;
        this.on = (...args) => {
            if (args[0] == "connect") {
                setTimeout( function() { window.solana.emitConnect(); }, 1);
            }
            return originalOn.apply(this, args);
        };
    }
    
    connect(payload) {
        console.log("yo solana connect");
        console.log(payload);
        // TODO: should either respond with a latest account or request account from user
        this.isConnected = true;
        const publicKey = new PublicKey("26qv4GCcx98RihuK3c4T6ozB3J7L6VwCuFVc7Ta2A3Uo");
        return Promise.resolve({ publicKey: publicKey });
    }
    
    disconnect() {}
    
    setAddress(address) {
        
    }
    
    updateAccount(eventName, addresses, chainId, rpcUrl) {
        window.solana.setAddress(addresses[0]);
        
        if (eventName == "switchAccount") {
//            provider.on("accountChanged", (publicKey: PublicKey | null));
//            window.ethereum.emit("accountsChanged", addresses);
            // TODO: support emitting accountChanged
        }
    }
    
    request(payload) {
        console.log("yo solana request");
        console.log(payload);
        return this._request(payload, false);
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
                // Some dapps do not get responses sent without a delay.
                // e.g., nftx.io does not start with a latest account if response is sent without a delay.
                setTimeout( function() {
                    if (error) {
                        reject(error);
                    } else {
                        resolve(data);
                    }
                }, 1);
            });
            this.wrapResults.set(payload.id, wrapResult);
            switch (payload.method) {
                case "eth_accounts":
                case "eth_sign":
                case "eth_requestAccounts":
                    return this._processPayload(payload);
                case "eth_newFilter":
                case "eth_newBlockFilter":
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
    
    emitConnect() {
        console.log("yo solana emit connect");
        this.emit("connect");
    }
    
    /**
     * @private Internal js -> native message handler
     */
    postMessage(handler, id, data) {
        let object = {
            id: id,
            name: handler,
            object: data,
            address: this.address,
            networkId: this.net_version(),
            host: window.location.host
        };
        window.tokenary.postMessage(object);
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

module.exports = TokenarySolana;
