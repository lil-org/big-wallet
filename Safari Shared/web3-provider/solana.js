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
        // support also via request "disconnect" method
    }

    // provider.on("accountChanged", (publicKey: PublicKey | null));
    // TODO: support emitting accountChanged (on switch account event)

    signTransaction(transaction) {
        
    }
    
    signAllTransactions(transactions) {
        
    }
    
    signAndSendTransaction(transaction) {
        // should return a promise with a signature

        // usage example
//        const transaction = new Transaction();
//        const { signature } = await window.solana.signAndSendTransaction(transaction);

        // You can also specify a SendOptions object as a second argument into signAndSendTransaction or as an options parameter when using request.
        // https://solana-labs.github.io/solana-web3.js/modules.html#SendOptions
//        SendOptions: { preflightCommitment?: Commitment; skipPreflight?: boolean };

        // there are also two deprecated methods to sign transactions without sending, idk if i should support em
        // https://github.com/phantom-labs/docs/blob/master/integrating/sending-a-transaction.md#deprecated-methods
    }

    signMessage(encodedMessage, display) {
        var params = {message: encodedMessage};
        if (typeof display !== "undefined") {
            params.display = display;
        }
        return this.request({method: "signMessage", params: params});
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
        
        // signAndSendTransaction request usage example
//        const transaction = new Transaction();
//        const { signature } = await window.solana.request({
//            method: "signAndSendTransaction",
//            params: {
//                 message: bs58.encode(transaction.serializeMessage()),
//            },
//        });

        // signMessage request usage example
//        const signedMessage = await window.solana.request({
//            method: "signMessage",
//            params: {
//                 message: encodedMessage,
//                 display: "hex",
//            },
//        });
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
                    this.emitConnect();
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
            return;
        }
        
        if ("publicKey" in response) { // TODO: validate non-empty?
            this.isConnected = true;
            const publicKey = new PublicKey(response.publicKey);
            this.publicKey = publicKey;
            this.sendResponse(id, {publicKey: publicKey});
            this.emitConnect();
        }
        
        if ("result" in response) {
            this.sendResponse(id, response.result);
        }
    }

    postMessage(handler, id, data) {
        let object = {
            object: data,
            publicKey: "", // pass current public key if available
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
