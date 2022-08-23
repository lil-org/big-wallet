// Copyright © 2022 Tokenary. All rights reserved.

"use strict";

import Utils from "./utils";
import IdMapping from "./id_mapping";
import { EventEmitter } from "events";
import bs58 from "bs58";

class PublicKey {
    
    constructor(value) {
        this.stringValue = value;
    }
    
    equals(publicKey) {
        return this.stringValue == publicKey.toString();
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
        return bs58.decode(this.stringValue);
    }
    
    toString() {
        return this.stringValue;
    }
    
}

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

    connect(params) {
        var payload = {method: "connect"};
        if (typeof params !== "undefined") {
            payload.params = params;
        }
        return this.request(payload);
    }

    externalDisconnect() {
        this.disconnect();
    }
    
    disconnect() {
        this.isConnected = false;
        this.publicKey = null;
        this.emit("disconnect");
    }

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

    signAndSendTransaction(transaction, options) {
        var params = {message: bs58.encode(transaction.serializeMessage())};
        if (typeof options !== "undefined") {
            params.options = options;
        }
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
        if (payload.method == "disconnect") {
            return this.disconnect();
        }
        
        this.idMapping.tryFixId(payload);
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
                    return;
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
                    if ("params" in payload && "onlyIfTrusted" in payload.params && payload.params.onlyIfTrusted) {
                        this.sendError(payload.id, "Click a button to connect");
                        return;
                    } else {
                        return this.postMessage("connect", payload.id, {});
                    }
                } else {
                    this.isConnected = true;
                    this.emitConnect(this.publicKey);
                    return this.sendResponse(payload.id, {publicKey: this.publicKey});
                }
            case "signMessage":
                if (typeof payload.params.message !== "string") {
                    payload.params.message = Utils.bufferToHex(payload.params.message);
                }
                return this.postMessage("signMessage", payload.id, payload);
            case "signTransaction":
                return this.postMessage("signTransaction", payload.id, payload);
            case "signAllTransactions":
                return this.postMessage("signAllTransactions", payload.id, payload);
            case "signAndSendTransaction":
                return this.postMessage("signAndSendTransaction", payload.id, payload);
        }
    }

    emitConnect(publicKey) {
        this.emit("connect", publicKey);
    }

    processTokenaryResponse(id, response) {
        if (response.name == "didLoadLatestConfiguration") {
            this.didGetLatestConfiguration = true;
            if ("publicKey" in response) {
                const publicKey = new PublicKey(response.publicKey);
                this.publicKey = publicKey;
            }
            
            for(let payload of this.pendingPayloads) {
                this.processPayload(payload);
            }
            
            this.pendingPayloads = [];
        } else if ("publicKey" in response) {
            this.isConnected = true;
            const publicKey = new PublicKey(response.publicKey);
            this.publicKey = publicKey;
            this.sendResponse(id, {publicKey: publicKey});
            this.emitConnect(publicKey);
            if (response.name == "switchAccount") {
                this.emit("accountChanged", publicKey);
            }
        } else if ("result" in response) {
            if (response.name == "signTransaction" || response.name == "signAndSendTransaction") {
                if (this.transactionsPendingSignature.has(id)) {
                    const pending = this.transactionsPendingSignature.get(id);
                    this.transactionsPendingSignature.delete(id);
                    const buffer = Utils.messageToBuffer(bs58.decode(response.result));
                    const transaction = pending[0];
                    transaction.addSignature(this.publicKey, buffer);
                    this.sendResponse(id, transaction);
                } else {
                    this.sendResponse(id, {signature: response.result, publicKey: this.publicKey.toString()});
                }
            } else {
                if (this.respondWithBuffer.get(id) === true) {
                    this.respondWithBuffer.delete(id);
                    const buffer = Utils.messageToBuffer(bs58.decode(response.result));
                    this.sendResponse(id, {signature: buffer, publicKey: this.publicKey});
                } else {
                    this.sendResponse(id, {signature: response.result, publicKey: this.publicKey.toString()});
                }
            }
        } else if ("results" in response) {
            if (this.transactionsPendingSignature.has(id)) {
                const transactions = this.transactionsPendingSignature.get(id);
                this.transactionsPendingSignature.delete(id);
                response.results.forEach( (signature, index) => {
                    const buffer = Utils.messageToBuffer(bs58.decode(signature));
                    transactions[index].addSignature(this.publicKey, buffer);
                });
                this.sendResponse(id, transactions);
            } else {
                this.sendResponse(id, {signatures: response.results, publicKey: this.publicKey.toString()});
            }
        } else if ("error" in response) {
            this.respondWithBuffer.delete(id);
            this.transactionsPendingSignature.delete(id);
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
