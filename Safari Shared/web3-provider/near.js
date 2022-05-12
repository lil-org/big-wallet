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
        // TODO: clean up
        console.log("yo requestSignIn");
        console.log(params);
        console.log(payload);
        return this.request(payload);
        
//        export interface RequestSignInParams {
//          contractId: string;
//          methodNames?: Array<string>;
//          amount?: string; // in yoctoⓃ
//        }
        
//        => Promise<RequestSignInResponse>;
        
        
//        interface AccessKey {
//          publicKey: {
//            data: Uint8Array;
//            keyType: number;
//          };
//          secretKey: string;
//        }
//
        
//        !!! accessKey is not actually used, there is only a check that if (accessKey)
        // top level sign in does not return anything
        
//        export interface RequestSignInResponse {
//          accessKey: AccessKey;
//          error:
//            | string
//            | {
//                type: string;
//              };
//          notificationId: number;
//          type: "sender-wallet-result";
//        }
        
        console.log("yo near requestSignIn");
        return;
    }
    
    getAccountId() {
//        => string | null;
        console.log("yo near getAccountId");
        return ""
    }
    
    signOut() {
//        => Promise<SignOutResponse>;
//        export type SignOutResponse = boolean | { error: string | { type: string } };
    }

    isSignedIn() {
        console.log("yo isSignedIn()");
        return true;
//        => boolean;
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
        console.log("yo signAndSendTransaction()");
//        params: SignAndSendTransactionParams
//        => Promise<SignAndSendTransactionResponse>;
        
//        export interface Action {
//          methodName: string;
//          args: object;
//          gas: string;
//          deposit: string;
//        }
//
//        export interface SignAndSendTransactionParams {
//          receiverId: string;
//          actions: Array<Action>;
//        }
//
//        // Seems to reuse signAndSendTransactions internally, hence the wrong method name and list of responses.
//        export interface SignAndSendTransactionResponse {
//          actionType: "DAPP/DAPP_POPUP_RESPONSE";
//          method: "signAndSendTransactions";
//          notificationId: number;
//          error?: string;
//          response?: Array<providers.FinalExecutionOutcome>;
//          type: "sender-wallet-extensionResult";
//        }
        
        // !!! in fact only response field is necessary and used in provider
//
//        export interface SignAndSendTransactionsResponse {
//          actionType: "DAPP/DAPP_POPUP_RESPONSE";
//          method: "signAndSendTransactions";
//          notificationId: number;
//          error?: string;
//          response?: Array<providers.FinalExecutionOutcome>;
//          type: "sender-wallet-extensionResult";
//        }
    }
        
    requestSignTransactions(params) {
        console.log("yo requestSignTransactions");
        //    params: RequestSignTransactionsParams
//        => Promise<SignAndSendTransactionsResponse>;
        
//        export interface Transaction {
//          receiverId: string;
//          actions: Array<Action>;
//        }
//
//        export interface RequestSignTransactionsParams {
//          transactions: Array<Transaction>;
//        }

    }
    
    // TODO: idk if this one is neseccary
//    request(method, params) {
//        console.log("yo near request");
//        //    method: string, params: Object
//        // => Object
//        // https://docs.near.org/docs/api/rpc
//    }
    
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
                case "signIn": // TODO: add more methods
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
        }
    }
    
    processTokenaryResponse(id, response) {
        if (response.name == "didLoadLatestConfiguration") {
            this.didGetLatestConfiguration = true;
            // TODO: apply latest configuration
            for(let payload of this.pendingPayloads) {
                this.processPayload(payload);
            }
            
            this.pendingPayloads = [];
        }
    }

    postMessage(handler, id, data) {
        var account = "";
        if (this.accountId) {
            account = this.accountId();
        }
        
        let object = {
            object: data,
            account: account,
        };
        
        // TODO: clean up
        console.log("yo post message");
        console.log(object);
        
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

    sendError(id, error) {
        console.log(`<== ${id} sendError ${error}`);
        let callback = this.callbacks.get(id);
        if (callback) {
            callback(error instanceof Error ? error : new Error(error), null);
            this.callbacks.delete(id);
        }
    }
}

module.exports = TokenaryNear;
