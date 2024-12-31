// ∅ 2025 lil org
// Rewrite of rpc.js from trust-web3-provider.

"use strict";

class RPCServer {
    
    constructor(chainId) {
        this.chainId = chainId;
    }
    
    call(payload) {
        payload.jsonrpc = "2.0";
        window.postMessage({direction: "rpc", message: {id: payload.id, subject: "rpc", chainId: this.chainId, body: JSON.stringify(payload)}}, "*");
        return true;
    }
}

module.exports = RPCServer;
