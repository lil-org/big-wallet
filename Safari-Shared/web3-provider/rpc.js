// Copyright © 2021 Tokenary. All rights reserved.
// Rewrite of rpc.js from trust-web3-provider.

"use strict";

class RPCServer {
    constructor(rpcUrl) {
        this.rpcUrl = rpcUrl;
    }
    
    call(payload) {
        return fetch(this.rpcUrl, {
        method: "POST",
        headers: {
            "Accept": "application/json",
            "Content-Type": "application/json"
        },
        body: JSON.stringify(payload)
        })
        .then(response => response.json())
        .then(json => {
            if (!json.result && json.error) {
                console.log("<== rpc error", json.error);
                throw new Error(json.error.message || "rpc error");
            }
            return json;
        });
    }
}

module.exports = RPCServer;
