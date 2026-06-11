// ∅ 2026 lil org
// Rewrite of utils.js from trust-web3-provider.

"use strict";

import { Buffer } from "buffer";

class Utils {
    static genId() {
        return new Date().getTime() + Math.floor(Math.random() * 1000);
    }
    
    // message: Bytes | string
    static messageToBuffer(message) {
        var buffer = Buffer.from([]);
        try {
            if ((typeof (message) === "string")) {
                buffer = Buffer.from(message.replace("0x", ""), "hex");
            } else {
                buffer = Buffer.from(message);
            }
        } catch (err) {
            console.log(`messageToBuffer error: ${err}`);
        }
        return buffer;
    }
    
    static bufferToHex(buf) {
        return "0x" + Buffer.from(buf).toString("hex");
    }
}

module.exports = Utils;
