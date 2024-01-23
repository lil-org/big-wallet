// ∅ 2024 lil org
// Rewrite of rpc.js from trust-web3-provider.

"use strict";

class RPCServer {
    
    constructor(chainId) {
        this.chainId = chainId;
    }
    
    call(payload) {
        window.postMessage({direction: "rpc", message: {id: payload.id, subject: "rpc", chainId: this.chainId, body: JSON.stringify(payload)}}, "*");
        return true;
    }
}

module.exports = RPCServer;
