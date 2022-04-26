// Copyright © 2022 Tokenary. All rights reserved.

"use strict";

import RPCServer from "./rpc";
import ProviderRpcError from "./error";
import Utils from "./utils";
import IdMapping from "./id_mapping";
import { EventEmitter } from "events";
import isUtf8 from "isutf8";
import { PublicKey, Transaction } from "@solana/web3.js";
import bs58 from "bs58";

class TokenarySolana extends EventEmitter {
    
    constructor() {
        super();

        this.idMapping = new IdMapping();
        this.callbacks = new Map();
        
        this.respondWithBuffer = new Map();
        this.transactionsPendingSignature = new Map();

        this.isPhantom = true;
        this.publicKey = null;
        this.isConnected = false;
        this.isTokenary = true;

        this.didGetLatestConfiguration = false;
        this.pendingPayloads = [];
    }

    connect() {
        return this.request({method: "connect"});
    }

    disconnect() {
        // TODO: implement
        // support also via request "disconnect" method
    }

    // provider.on("accountChanged", (publicKey: PublicKey | null));
    // TODO: support emitting accountChanged (on switch account event)

    signTransaction(transaction) {
        const params = {message: bs58.encode(transaction.serializeMessage())};
        const payload = {method: "signTransaction", params: params, id: Utils.genId()};
        this.transactionsPendingSignature.set(payload.id, [transaction]);
        return this.request(payload);
    }
    
    signAllTransactions(transactions) {
        const messages = transactions.map(transaction => {
            return bs58.encode(transaction.serializeMessage());
        });
        const params = {messages: messages};
        const payload = {method: "signAllTransactions", params: params, id: Utils.genId()};
        this.transactionsPendingSignature.set(payload.id, transactions);
        return this.request(payload);
    }

    signAndSendTransaction(transaction) {
        const params = {message: bs58.encode(transaction.serializeMessage())};
        return this.request({method: "signAndSendTransaction", params: params});
    }
    
    signMessage(encodedMessage, display) {
        var params = {message: encodedMessage};
        if (typeof display !== "undefined") {
            params.display = display;
        }
        const payload = {method: "signMessage", params: params, id: Utils.genId()};
        this.respondWithBuffer.set(payload.id, true);
        return this.request(payload);
    }

    request(payload) {
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
            switch (payload.method) {
                case "connect":
                case "signMessage":
                case "signTransaction":
                case "signAllTransactions":
                case "signAndSendTransaction":
                    return this.processPayload(payload);
                default:
                    this.callbacks.delete(payload.id);
                    return this.rpc
                    .call(payload)
                    .then((response) => {
                        resolve(response.result);
                    })
                    .catch(reject);
            }
        });
    }
    
    processPayload(payload) {
        if (!this.didGetLatestConfiguration) {
            this.pendingPayloads.push(payload);
            return;
        }
        
        switch (payload.method) {
            case "connect":
                if (!this.publicKey) {
                    return this.postMessage("connect", payload.id, {});
                } else {
                    this.isConnected = true;
                    this.emitConnect(this.publicKey);
                    return this.sendResponse(payload.id, {publicKey: this.publicKey});
                }
            case "signMessage":
                return this.postMessage("signMessage", payload.id, payload);
        }
    }

    emitConnect() {
        this.emit("connect");
    }

    processTokenaryResponse(id, response) {
        if (response.name == "didLoadLatestConfiguration") {
            this.didGetLatestConfiguration = true;
            if ("publicKey" in response) { // TODO: validate non-empty?
                const publicKey = new PublicKey(response.publicKey);
                this.publicKey = publicKey;
            }
            
            for(let payload of this.pendingPayloads) {
                this.processPayload(payload);
            }
            
            this.pendingPayloads = [];
        } else if ("publicKey" in response) { // TODO: validate non-empty?
            this.isConnected = true;
            const publicKey = new PublicKey(response.publicKey);
            this.publicKey = publicKey;
            this.sendResponse(id, {publicKey: publicKey});
            this.emitConnect(publicKey);
        } else if ("result" in response) {
            this.sendResponse(id, response.result);
        } else if ("error" in response) {
            this.sendError(id, response.error);
        }
    }

    postMessage(handler, id, data) {
        var publicKey = "";
        if (this.publicKey) {
            publicKey = this.publicKey.toString();
        }
        
        let object = {
            object: data,
            publicKey: publicKey,
        };
        window.tokenary.postMessage(handler, id, object, "solana");
    }

    sendResponse(id, result) {
        let originId = this.idMapping.tryPopId(id) || id;
        let callback = this.callbacks.get(id);
        if (callback) {
            callback(null, result);
            this.callbacks.delete(id);
        } else {
            console.log(`callback id: ${id} not found`);
        }
    }

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
