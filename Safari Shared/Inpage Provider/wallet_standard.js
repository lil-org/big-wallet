// ∅ 2026 lil org

"use strict";

export const walletName = "Big Wallet";
export const walletStandardRegisterEvent = "wallet-standard:register-wallet";

export function makeWalletStandardRegistrationCallback({
    isActive,
    onError,
    registeredHosts = new WeakSet,
    registrationDisposers = new Set,
    wallet,
}) {
    let active = true;
    const callback = registration => {
        if (!active || !isActive() || !registration ||
            typeof registration.register !== "function" ||
            registeredHosts.has(registration)) {
            return;
        }
        registeredHosts.add(registration);
        try {
            const unregister = registration.register(wallet);
            if (typeof unregister === "function") {
                registrationDisposers.add(unregister);
            }
        } catch (error) {
            registeredHosts.delete(registration);
            onError?.(error);
        }
    };
    const deactivate = () => {
        if (!active) { return; }
        active = false;
        for (const unregister of registrationDisposers) {
            try { unregister(); } catch {}
        }
        registrationDisposers.clear();
    };
    return {callback, deactivate};
}

export function dispatchWalletStandardRegistrationEvent(callback, onError) {
    try {
        class WalletStandardRegistrationEvent extends Event {
            #detail;

            constructor(registrationCallback) {
                super(walletStandardRegisterEvent, {
                    bubbles: false,
                    cancelable: false,
                    composed: false,
                });
                this.#detail = registrationCallback;
            }

            get detail() { return this.#detail; }
            get type() { return walletStandardRegisterEvent; }
            preventDefault() { throw new Error("preventDefault cannot be called"); }
            stopImmediatePropagation() {
                throw new Error("stopImmediatePropagation cannot be called");
            }
            stopPropagation() {
                throw new Error("stopPropagation cannot be called");
            }
        }
        return window.dispatchEvent(
            new WalletStandardRegistrationEvent(callback)
        ) !== false;
    } catch (error) {
        onError?.(error);
        return false;
    }
}
