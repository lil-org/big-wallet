// Copyright © 2022 Tokenary. All rights reserved.

"use strict";

import Utils from "./utils";
import IdMapping from "./id_mapping";
import { EventEmitter } from "events";

class TokenaryNear extends EventEmitter {
    
    constructor() {
        super();
        
        this.accountId = null;
        this.idMapping = new IdMapping();
        this.callbacks = new Map();
        
        this.isSender = true;
        this.isTokenary = true;

        this.didGetLatestConfiguration = false;
        this.pendingPayloads = [];
    }
    
    requestSignIn(params) {
        const payload = {method: "signIn", params: params, id: Utils.genId()};
        return this.request(payload);
    }
    
    getAccountId() {
        return this.accountId;
    }
    
    signOut() {
        // TODO: implement
        // => Promise<boolean>;
    }

    // TODO: respond async maybe
    isSignedIn(contractId) {
        // asks for each contractId
        if (this.accountId) {
            return true;
        } else {
            return false;
        }
    }
        
//    export interface SenderEvents {
//      signIn: () => void;
//      signOut: () => void;
//      accountChanged: (changedAccountId: string) => void;
//      rpcChanged: (response: RpcChangedResponse) => void;
//    }
    
//    export interface RpcChangedResponse {
//      method: "rpcChanged";
//      notificationId: number;
//      rpc: RpcInfo;
//      type: "sender-wallet-fromContent";
//    }

//on: <Event extends keyof SenderEvents>(
//  event: Event,
//  callback: SenderEvents[Event]
//) => void;
    
    signAndSendTransaction(params) {
        return this.requestSignTransactions({transactions: [params]});
    }
        
    requestSignTransactions(params) {
        const payload = {method: "signAndSendTransactions", params: params, id: Utils.genId()};
        return this.request(payload);
    }
    
    request(payload) {
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
                case "signIn":
                case "signAndSendTransactions":
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
            case "signIn":
                return this.postMessage("signIn", payload.id, payload);
                // TODO: respond right away if already got sign in info from latest configuration
            case "signAndSendTransactions":
                return this.postMessage("signAndSendTransactions", payload.id, payload);
        }
    }
    
    processTokenaryResponse(id, response) {
        if (response.name == "didLoadLatestConfiguration") {
            this.didGetLatestConfiguration = true;
            
            if ("account" in response) {
                this.accountId = response.account;
            }
            
            for(let payload of this.pendingPayloads) {
                this.processPayload(payload);
            }
            
            this.pendingPayloads = [];
        } else if ("account" in response) {
            this.accountId = response.account;
            this.sendResponse(id, {accessKey: true});
            // TODO: in case of error, near provider expects it here, not like other providers
            // TODO: implement switch account as well
        } else {
            if ("response" in response) {
                response.response = JSON.parse(response.response);
            }
            
            this.sendResponse(id, response);
        }
    }

    postMessage(handler, id, data) {
        var account = "";
        if (this.accountId) {
            account = this.accountId;
        }
        
        let object = {
            object: data,
            account: account,
        };
        
        window.tokenary.postMessage(handler, id, object, "near");
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
    
}

module.exports = TokenaryNear;
