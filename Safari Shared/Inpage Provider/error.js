// ∅ 2024 lil org
// Rewrite of error.js from trust-web3-provider.

"use strict";

class ProviderRpcError extends Error {
    constructor(code, message) {
        super();
        this.code = code;
        this.message = message;
    }
    
    toString() {
        return `${this.message} (${this.code})`;
    }
}

module.exports = ProviderRpcError;
