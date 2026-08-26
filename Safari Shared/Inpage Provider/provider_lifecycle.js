// ∅ 2026 lil org

"use strict";

const retiredProviders = new WeakSet();

export function isProviderRetired(provider) {
    return !!provider && retiredProviders.has(provider);
}

export function markProviderRetired(provider) {
    if (provider &&
        (typeof provider === "object" || typeof provider === "function")) {
        retiredProviders.add(provider);
    }
}
