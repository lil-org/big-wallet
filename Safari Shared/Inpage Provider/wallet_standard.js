// ∅ 2026 lil org

"use strict";

export const walletName = "Big Wallet";
export const walletStandardRegisterEvent = "wallet-standard:register-wallet";

export function makeWalletStandardRegistrationCallback({
    onError,
    wallet,
}) {
    const registeredHosts = new WeakSet;
    return registration => {
        if (!registration ||
            typeof registration.register !== "function" ||
            registeredHosts.has(registration)) {
            return;
        }
        registeredHosts.add(registration);
        try {
            registration.register(wallet);
        } catch (error) {
            registeredHosts.delete(registration);
            onError?.(error);
        }
    };
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
