// ∅ 2026 lil org

"use strict";

import {EventEmitter} from "events";
import {providerReplacementError} from "./error";
import {
    dispatchWalletStandardRegistrationEvent,
    makeWalletStandardRegistrationCallback,
    walletName,
} from "./wallet_standard";

export const stableFacadeVersion = 2;

const applyFunction = Reflect.apply;
const emitEvent = EventEmitter.prototype.emit;

const ethereumEvents = [
    "accountsChanged",
    "chainChanged",
    "disconnect",
    "message",
    "networkChanged",
    "_initialized",
];
const ethereumMethods = [
    "request",
    "send",
    "sendAsync",
    "enable",
    "isConnected",
    "isUnlocked",
];
const ethereumProperties = [
    "address",
    "chainId",
    "isBigWallet",
    "isMetaMask",
    "networkVersion",
    "ready",
    "selectedAddress",
    "_initialized",
    "_isConnected",
    "_isUnlocked",
    "_metamask",
];
const solanaEvents = ["connect", "disconnect", "accountChanged"];
const solanaMethods = [
    "connect",
    "request",
    "disconnect",
    "externalDisconnect",
    "signMessage",
    "signTransactionPayload",
    "signTransaction",
    "signAllTransactions",
    "signAndSendTransaction",
    "standardOn",
    "standardAccounts",
    "standardFeatures",
    "standardConnect",
    "standardDisconnect",
    "standardSignMessage",
    "standardSignTransaction",
    "standardSignAndSendTransaction",
];
const solanaProperties = [
    "providerGeneration",
    "publicKey",
    "isConnected",
    "didGetLatestConfiguration",
    "accountRevision",
    "accountRevocationTombstone",
    "solanaAuthorizationEpoch",
    "retired",
    "isPhantom",
    "isBigWallet",
];
const solanaChains = Object.freeze([
    "solana:mainnet",
    "solana:devnet",
    "solana:testnet",
]);
const supportedTransactionVersions = Object.freeze(["legacy", 0]);

function unavailable() {
    return providerReplacementError();
}

function target(value, name) {
    const normalized = value?.provider ? value : {provider: value};
    if (!normalized.provider ||
        (typeof normalized.provider !== "object" &&
            typeof normalized.provider !== "function")) {
        throw new TypeError(`${name} target is unavailable`);
    }
    return normalized;
}

function walletAccountData(source) {
    if (!source || typeof source.address !== "string" ||
        !Array.isArray(source.chains) || !Array.isArray(source.features) ||
        !ArrayBuffer.isView(source.publicKey)) {
        throw new TypeError("Wallet account is invalid");
    }
    return {
        address: source.address,
        chains: Object.freeze([...source.chains]),
        features: Object.freeze([...source.features]),
        label: typeof source.label === "string" ? source.label : walletName,
        publicKey: new Uint8Array(source.publicKey),
    };
}

function stableWalletAccount(entry) {
    return Object.freeze({
        get address() { return entry.data.address; },
        get publicKey() { return new Uint8Array(entry.data.publicKey); },
        get chains() { return entry.data.chains; },
        get features() { return entry.data.features; },
        get label() { return entry.data.label; },
    });
}

export function createStableFacadeRecord({icon = "", uuid} = {}) {
    if (typeof icon !== "string" || typeof uuid !== "string" || !uuid) {
        throw new TypeError("Stable facade identity is invalid");
    }

    let ethereumTarget = null;
    let solanaTarget = null;
    let ethereumForwarding = [];
    let solanaForwarding = [];
    let accounts = Object.freeze([]);
    let accountCache = new Map;
    let deliveredConnect = false;
    let registration = null;
    const subscriptions = new Set;
    const ethereum = new EventEmitter;
    const solana = new EventEmitter;

    const ethereumProvider = () => ethereumTarget?.provider || null;
    const solanaProvider = () => solanaTarget?.provider || null;

    function callEthereum(name, arguments_) {
        const provider = ethereumProvider();
        const method = provider?.[name];
        if (typeof method !== "function") {
            return name === "isConnected" ? false : Promise.reject(unavailable());
        }
        return method.apply(provider, arguments_);
    }

    for (const name of ethereumMethods) {
        Object.defineProperty(ethereum, name, {
            value(...arguments_) { return callEthereum(name, arguments_); },
        });
    }
    for (const name of ethereumProperties) {
        Object.defineProperty(ethereum, name, {
            enumerable: true,
            get() { return ethereumProvider()?.[name]; },
            set(value) {
                const provider = ethereumProvider();
                if (provider) { provider[name] = value; }
            },
        });
    }

    const emitterMethods = [
        "addListener",
        "emit",
        "eventNames",
        "getMaxListeners",
        "listenerCount",
        "listeners",
        "off",
        "on",
        "once",
        "prependListener",
        "prependOnceListener",
        "rawListeners",
        "removeAllListeners",
        "removeListener",
        "setMaxListeners",
    ];
    const listenerMethods = new Set([
        "addListener",
        "on",
        "once",
        "prependListener",
        "prependOnceListener",
    ]);
    for (const name of emitterMethods) {
        const original = EventEmitter.prototype[name];
        if (typeof original !== "function") { continue; }
        Object.defineProperty(ethereum, name, {
            value(...arguments_) {
                if (name === "emit" && arguments_[0] === "connect") {
                    return false;
                }
                const result = original.apply(ethereum, arguments_);
                if (arguments_[0] === "connect" && listenerMethods.has(name)) {
                    replayConnect();
                }
                return result;
            },
        });
    }

    function replayConnect() {
        const current = ethereumTarget;
        if (!current || deliveredConnect ||
            ethereum.listenerCount("connect") === 0 ||
            typeof current.requestConnectReplay !== "function") {
            return false;
        }
        return current.requestConnectReplay(payload => {
            if (deliveredConnect || ethereumTarget !== current ||
                ethereum.listenerCount("connect") === 0) {
                return false;
            }
            deliveredConnect = true;
            applyFunction(emitEvent, ethereum, ["connect", payload]);
            return true;
        }) !== false;
    }

    function detachEthereum() {
        for (const {provider, eventName, listener} of ethereumForwarding) {
            provider.removeListener?.(eventName, listener);
        }
        ethereumForwarding = [];
    }

    function attachEthereum(current) {
        detachEthereum();
        if (!current) { return; }
        for (const eventName of ethereumEvents) {
            const listener = (...arguments_) => {
                if (ethereumTarget === current) {
                    if (eventName === "disconnect") {
                        deliveredConnect = false;
                        replayConnect();
                    }
                    applyFunction(
                        emitEvent,
                        ethereum,
                        [eventName, ...arguments_]
                    );
                }
            };
            current.provider.on?.(eventName, listener);
            ethereumForwarding.push({
                eventName,
                listener,
                provider: current.provider,
            });
        }
    }

    function refreshAccounts(current = solanaTarget) {
        if (!current ||
            typeof current.provider.standardAccounts !== "function") {
            return accounts;
        }
        const values = current.provider.standardAccounts();
        if (!Array.isArray(values) || values.length > 64) {
            throw new TypeError("Solana accounts are invalid");
        }
        const nextCache = new Map;
        const nextAccounts = values.map(value => {
            const data = walletAccountData(value);
            if (nextCache.has(data.address)) {
                throw new TypeError("Solana account addresses are duplicated");
            }
            const entry = accountCache.get(data.address) || {data, account: null};
            entry.data = data;
            entry.account ||= stableWalletAccount(entry);
            nextCache.set(data.address, entry);
            return entry.account;
        });
        if (current === solanaTarget) {
            accountCache = nextCache;
            accounts = Object.freeze(nextAccounts);
        }
        return Object.freeze(nextAccounts);
    }

    function bindSubscription(subscription) {
        subscription.dispose?.();
        subscription.dispose = null;
        const provider = solanaProvider();
        if (!provider || typeof provider.standardOn !== "function") {
            throw unavailable();
        }
        subscription.dispose = provider.standardOn(
            subscription.eventName,
            (...arguments_) => {
                if (!subscription.active || provider !== solanaProvider()) {
                    return;
                }
                const values = subscription.eventName === "change"
                    ? [{accounts: refreshAccounts()}]
                    : arguments_;
                subscription.listener(...values);
            }
        );
    }

    function standardOn(eventName, listener) {
        if (typeof eventName !== "string" || typeof listener !== "function") {
            throw unavailable();
        }
        const subscription = {
            active: true,
            dispose: null,
            eventName,
            listener,
        };
        bindSubscription(subscription);
        subscriptions.add(subscription);
        return () => {
            if (!subscription.active) { return; }
            subscription.active = false;
            subscription.dispose?.();
            subscriptions.delete(subscription);
        };
    }

    function callSolana(name, arguments_) {
        const provider = solanaProvider();
        const method = provider?.[name];
        return typeof method === "function"
            ? method.apply(provider, arguments_)
            : Promise.reject(unavailable());
    }

    for (const name of solanaMethods) {
        Object.defineProperty(solana, name, {
            value(...arguments_) { return callSolana(name, arguments_); },
        });
    }
    for (const name of solanaProperties) {
        Object.defineProperty(solana, name, {
            enumerable: true,
            get() { return solanaProvider()?.[name]; },
            set(value) {
                const provider = solanaProvider();
                if (provider) { provider[name] = value; }
            },
        });
    }

    function detachSolana() {
        for (const {provider, eventName, listener} of solanaForwarding) {
            provider.removeListener?.(eventName, listener);
        }
        solanaForwarding = [];
    }

    function attachSolana(current) {
        detachSolana();
        if (!current) { return; }
        for (const eventName of solanaEvents) {
            const listener = (...arguments_) => {
                if (solanaTarget === current) {
                    applyFunction(
                        emitEvent,
                        solana,
                        [eventName, ...arguments_]
                    );
                }
            };
            current.provider.on?.(eventName, listener);
            solanaForwarding.push({
                eventName,
                listener,
                provider: current.provider,
            });
        }
    }

    const features = Object.freeze({
        "standard:connect": Object.freeze({
            version: "1.0.0",
            connect: (...arguments_) => callSolana("standardConnect", arguments_),
        }),
        "standard:disconnect": Object.freeze({
            version: "1.0.0",
            disconnect: (...arguments_) => callSolana("standardDisconnect", arguments_),
        }),
        "standard:events": Object.freeze({version: "1.0.0", on: standardOn}),
        "solana:signAndSendTransaction": Object.freeze({
            version: "1.0.0",
            supportedTransactionVersions,
            signAndSendTransaction: (...arguments_) => callSolana(
                "standardSignAndSendTransaction",
                arguments_
            ),
        }),
        "solana:signTransaction": Object.freeze({
            version: "1.0.0",
            supportedTransactionVersions,
            signTransaction: (...arguments_) => callSolana(
                "standardSignTransaction",
                arguments_
            ),
        }),
        "solana:signMessage": Object.freeze({
            version: "1.1.0",
            signMessage: (...arguments_) => callSolana(
                "standardSignMessage",
                arguments_
            ),
        }),
    });
    const wallet = Object.freeze({
        get version() { return "1.0.0"; },
        get name() { return walletName; },
        get icon() { return icon; },
        get chains() { return solanaChains; },
        get features() { return features; },
        get accounts() {
            try { return refreshAccounts(); } catch { return accounts; }
        },
    });
    const info = Object.freeze({
        uuid,
        name: "Big Wallet",
        icon,
        rdns: "org.lil.wallet",
    });
    const eip6963 = Object.freeze({info, provider: ethereum, uuid});
    const announcementDetail = Object.freeze({info, provider: ethereum});

    function prepareTargets(values = {}) {
        const nextEthereum = target(values.ethereumProvider, "Ethereum");
        const nextSolana = target(values.solanaProvider, "Solana");
        if (typeof nextEthereum.requestConnectReplay !== "function") {
            throw new TypeError("Ethereum target is invalid");
        }
        if (typeof nextSolana.provider.standardAccounts !== "function") {
            throw new TypeError("Solana accounts are unavailable");
        }
        nextSolana.provider.standardAccounts().map(walletAccountData);
        let finished = false;
        return Object.freeze({
            commit() {
                if (finished) { return null; }
                finished = true;
                const previous = Object.freeze({
                    ethereum: ethereumTarget,
                    solana: solanaTarget,
                });
                ethereumTarget = nextEthereum;
                solanaTarget = nextSolana;
                attachEthereum(nextEthereum);
                attachSolana(nextSolana);
                refreshAccounts();
                for (const subscription of subscriptions) {
                    bindSubscription(subscription);
                }
                replayConnect();
                return previous;
            },
            rollback() {
                if (finished) { return false; }
                finished = true;
                return true;
            },
        });
    }

    function snapshots() {
        const ethereumSnapshot = ethereumTarget?.snapshot?.() || null;
        const solanaSnapshot = solanaTarget?.snapshot?.() || null;
        return Object.freeze({ethereum: ethereumSnapshot, solana: solanaSnapshot});
    }

    function announceEthereum() {
        return window.dispatchEvent(new CustomEvent(
            "eip6963:announceProvider",
            {detail: announcementDetail}
        )) !== false;
    }

    function ensureWalletRegistration() {
        if (registration) { return wallet; }
        registration = makeWalletStandardRegistrationCallback({
            isActive: () => true,
            registeredHosts: new WeakSet,
            registrationDisposers: new Set,
            wallet,
        });
        dispatchWalletStandardRegistrationEvent(registration.callback);
        window.addEventListener(
            "wallet-standard:app-ready",
            event => registration.callback(event.detail)
        );
        const host = window.navigator?.wallets;
        if (host == null) {
            window.navigator.wallets = [registration.callback];
        } else if (typeof host.push === "function") {
            host.push(registration.callback);
        }
        return wallet;
    }

    const bigwallet = Object.freeze({eth: ethereum, solana});
    const web3 = Object.freeze({currentProvider: ethereum});

    return Object.freeze({
        announceEthereum,
        bigwallet,
        eip6963,
        ethereum,
        ensureWalletRegistration,
        prepareTargets,
        snapshots,
        solana,
        version: stableFacadeVersion,
        wallet,
        web3,
    });
}

export function reusableStableFacadeRecord(value) {
    if (!Object.isFrozen(value) || value.version !== stableFacadeVersion) {
        return null;
    }
    const provider = value.eip6963?.provider;
    return provider && typeof provider.request === "function" &&
        typeof provider.on === "function" &&
        typeof value.prepareTargets === "function" &&
        typeof value.snapshots === "function" &&
        value.ethereum === provider &&
        typeof value.solana?.connect === "function" &&
        value.wallet?.name === walletName
        ? value
        : null;
}
