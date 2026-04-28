// ∅ 2026 lil org
// Rewrite of error.js from trust-web3-provider.

"use strict";

class ProviderRpcError extends Error {
    constructor(code, message, data) {
        super();
        this.code = code;
        this.message = message;
        if (typeof data !== "undefined") {
            this.data = data;
        }
    }
    
    toString() {
        return `${this.message} (${this.code})`;
    }
}

module.exports = ProviderRpcError;
