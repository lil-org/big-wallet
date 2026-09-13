// ∅ 2026 lil org

"use strict";

import {freezeObjectNormally} from "./intrinsics";

export const walletName = "Big Wallet";
export const walletStandardRegisterEvent = "wallet-standard:register-wallet";
export const solanaMainnetChain = "solana:mainnet";
export const solanaDevnetChain = "solana:devnet";
export const solanaTestnetChain = "solana:testnet";
export const solanaChains = freezeObjectNormally([
    solanaMainnetChain,
    solanaDevnetChain,
    solanaTestnetChain,
]);

const supportedTransactionVersions = freezeObjectNormally(["legacy", 0]);

export function makeWalletStandardFeatures({
    connect,
    disconnect,
    on,
    signAndSendTransaction,
    signTransaction,
    signMessage,
}) {
    return freezeObjectNormally({
        "standard:connect": freezeObjectNormally({version: "1.0.0", connect}),
        "standard:disconnect": freezeObjectNormally({version: "1.0.0", disconnect}),
        "standard:events": freezeObjectNormally({version: "1.0.0", on}),
        "solana:signAndSendTransaction": freezeObjectNormally({
            version: "1.0.0",
            supportedTransactionVersions,
            signAndSendTransaction,
        }),
        "solana:signTransaction": freezeObjectNormally({
            version: "1.0.0",
            supportedTransactionVersions,
            signTransaction,
        }),
        "solana:signMessage": freezeObjectNormally({version: "1.1.0", signMessage}),
    });
}

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
