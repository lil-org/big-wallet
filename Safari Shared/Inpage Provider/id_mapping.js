// ∅ 2026 lil org

"use strict";

import Utils from "./utils";

class IdMapping {
    
    constructor() {
        this.intIds = new Map;
    }
    
    nextAvailableId() {
        let id = Utils.genId();
        if (!Number.isSafeInteger(id)) {
            id = 0;
        }
        while (this.intIds.has(id)) {
            id = id === Number.MAX_SAFE_INTEGER ? 0 : id + 1;
        }
        return id;
    }

    tryFixId(payload) {
        const hasNonFiniteNumberId =
            typeof payload.id === "number" && !Number.isFinite(payload.id);
        const hasFiniteUnsafeNumberId =
            typeof payload.id === "number" &&
            Number.isFinite(payload.id) &&
            !Number.isSafeInteger(payload.id);
        if (typeof payload.id === "undefined" || hasNonFiniteNumberId) {
            payload.id = this.nextAvailableId();
            this.intIds.set(payload.id, payload.id);
        } else if (typeof payload.id !== "number" || hasFiniteUnsafeNumberId ||
            this.intIds.has(payload.id)) {
            const newId = this.nextAvailableId();
            this.intIds.set(newId, payload.id);
            payload.id = newId;
        } else {
            this.intIds.set(payload.id, payload.id);
        }
    }
    
    tryPopId(id) {
        if (!this.intIds.has(id)) {
            return undefined;
        }
        const originId = this.intIds.get(id);
        this.intIds.delete(id);
        return originId;
    }
}

module.exports = IdMapping;
