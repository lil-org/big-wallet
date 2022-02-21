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
        
        // TODO: process with request function
        
        this.postMessage("connect", 69, {});
        // TODO: should either respond with a latest account or request account from user
        this.isConnected = true; // TODO: should set to true only after successful account selection
        const publicKey = new PublicKey("26qv4GCcx98RihuK3c4T6ozB3J7L6VwCuFVc7Ta2A3Uo");
        return Promise.resolve({ publicKey: publicKey });
    }

    disconnect() {}

    setAddress(address) {

    }

    // provider.on("accountChanged", (publicKey: PublicKey | null));
    // TODO: support emitting accountChanged (on switch account event)

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
//        display == "utf8"
        // const signedMessage = await window.solana.signMessage(encodedMessage, "utf8");
    }

    request(payload) {
        // Support connecting via request
        // also "disconnect"
//        payload.method == "connect"

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

        console.log("yo solana request");
        console.log(payload);
        return this._request(payload);
    }

    _request(payload) {
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
                case "eth_accounts":
                case "eth_sign":
                case "eth_requestAccounts":
                    return this._processPayload(payload);
                case "eth_newFilter":
                case "eth_newBlockFilter":
                    throw new ProviderRpcError(4200, `Tokenary does not support calling ${payload.method}. Please use your own solution`);
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

    emitConnect() {
        this.emit("connect");
    }

    processTokenaryResponse(response) {

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
