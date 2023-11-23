// Copyright © 2021 Tokenary. All rights reserved.
// Rewrite of id_mapping.js from trust-web3-provider.

"use strict";

import Utils from "./utils";

class IdMapping {
    
    constructor() {
        this.intIds = new Map;
    }
    
    tryFixId(payload) {
        if (!payload.id) {
            payload.id = Utils.genId();
            this.intIds.set(payload.id, payload.id);
        } else if (typeof payload.id !== "number" || this.intIds.has(payload.id) ) {
            let newId = Utils.genId();
            this.intIds.set(newId, payload.id);
            payload.id = newId;
        } else {
            this.intIds.set(payload.id, payload.id);
        }
    }
    
    tryPopId(id) {
        let originId = this.intIds.get(id);
        if (originId) {
            this.intIds.delete(id);
        }
        return originId;
    }
}

module.exports = IdMapping;
