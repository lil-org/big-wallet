// ∅ 2026 lil org

"use strict";

import {EventEmitter} from "events";
import {providerReplacementError} from "./error";
import {
    dispatchWalletStandardRegistrationEvent,
    makeWalletStandardFeatures,
    makeWalletStandardRegistrationCallback,
    solanaAccountFeatures,
    solanaChains,
    walletName,
} from "./wallet_standard";

export const stableFacadeVersion = 2;

const applyFunction = Reflect.apply;
const emitEvent = EventEmitter.prototype.emit;
const forEachSet = Set.prototype.forEach;
const setTimeoutNormally = setTimeout;

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
        !ArrayBuffer.isView(source.publicKey)) {
        throw new TypeError("Wallet account is invalid");
    }
    return {
        address: source.address,
        chains: solanaChains,
        features: solanaAccountFeatures,
        label: walletName,
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
    let accountEntry = null;
    let disposeAccountChanges = null;
    let deliveredConnect = false;
    let observedReadyFlush = false;
    let connectReplayToken = null;
    let disposeReadiness = null;
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
                    scheduleConnectReplay();
                }
                return result;
            },
        });
    }

    function replayConnect(current) {
        if (!current || ethereumTarget !== current || deliveredConnect ||
            typeof current.withReadyState !== "function") {
            return false;
        }
        return current.withReadyState(payload => {
            if (deliveredConnect || ethereumTarget !== current ||
                ethereum.listenerCount("connect") === 0) {
                return false;
            }
            deliveredConnect = true;
            applyFunction(emitEvent, ethereum, ["connect", payload]);
            return true;
        }) !== false;
    }

    function scheduleConnectReplay({reserveTimer = false} = {}) {
        const current = ethereumTarget;
        if (!current || !reserveTimer && (deliveredConnect ||
            ethereum.listenerCount("connect") === 0) ||
            ethereumTarget !== current ||
            connectReplayToken?.target === current) {
            return;
        }
        const token = {target: current};
        connectReplayToken = token;
        try {
            applyFunction(setTimeoutNormally, undefined, [() => {
                if (connectReplayToken !== token) { return; }
                connectReplayToken = null;
                replayConnect(current);
            }, 1]);
        } catch {
            if (connectReplayToken === token) { connectReplayToken = null; }
        }
    }

    function detachEthereum() {
        disposeReadiness?.();
        disposeReadiness = null;
        connectReplayToken = null;
        for (const {provider, eventName, listener} of ethereumForwarding) {
            provider.removeListener?.(eventName, listener);
        }
        ethereumForwarding = [];
    }

    function attachEthereum(current) {
        detachEthereum();
        if (!current) { return; }
        disposeReadiness = current.subscribeReadiness(({flushed}) => {
            if (ethereumTarget !== current) { return; }
            if (flushed === true && !observedReadyFlush) {
                observedReadyFlush = true;
                replayConnect(current);
            }
            if (ethereumTarget === current) {
                scheduleConnectReplay({reserveTimer: true});
            }
        });
        for (const eventName of ethereumEvents) {
            const listener = (...arguments_) => {
                if (ethereumTarget === current) {
                    if (eventName === "disconnect") {
                        deliveredConnect = false;
                        if (current.snapshot?.()?.phase !== "retired") {
                            observedReadyFlush = false;
                        }
                        scheduleConnectReplay();
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

    function readAccount(current) {
        const value = current.provider.accountState();
        return value == null ? null : walletAccountData(value);
    }

    function refreshAccounts() {
        const current = solanaTarget;
        if (!current) { return accounts; }
        const data = readAccount(current);
        if (solanaTarget !== current) { return accounts; }
        if (!data) {
            accountEntry = null;
            accounts = Object.freeze([]);
        } else {
            if (accountEntry?.data.address !== data.address) {
                accountEntry = {data, account: null};
                accountEntry.account = stableWalletAccount(accountEntry);
            } else {
                accountEntry.data = data;
            }
            accounts = Object.freeze([accountEntry.account]);
        }
        return accounts;
    }

    function bindAccountChanges() {
        disposeAccountChanges?.();
        disposeAccountChanges = null;
        const current = solanaTarget;
        if (!current || subscriptions.size === 0) { return; }
        disposeAccountChanges = current.provider.onAccountChange(() => {
            if (solanaTarget !== current) { return; }
            const pending = [];
            applyFunction(forEachSet, subscriptions, [subscription => {
                pending[pending.length] = subscription;
            }]);
            for (let index = 0; index < pending.length; index += 1) {
                const subscription = pending[index];
                if (solanaTarget !== current) { return; }
                if (!subscription.active) { continue; }
                try {
                    const currentAccounts = refreshAccounts();
                    if (solanaTarget !== current) { return; }
                    subscription.listener({accounts: currentAccounts});
                } catch {}
            }
        });
    }

    function standardOn(eventName, listener) {
        if (typeof eventName !== "string" || typeof listener !== "function") {
            throw unavailable();
        }
        if (eventName !== "change") { return () => {}; }
        const subscription = {active: true, listener};
        subscriptions.add(subscription);
        if (subscriptions.size === 1) { bindAccountChanges(); }
        return () => {
            subscription.active = false;
            subscriptions.delete(subscription);
            if (subscriptions.size === 0) {
                disposeAccountChanges?.();
                disposeAccountChanges = null;
            }
        };
    }

    async function standardConnect(input) {
        const current = solanaTarget;
        const provider = solanaProvider();
        const silent = input?.silent === true;
        if (solanaTarget !== current) { throw unavailable(); }
        if (silent && provider?.didGetLatestConfiguration &&
            !provider.publicKey) {
            return {accounts: []};
        }
        try {
            await callSolana("connect", [silent
                ? {onlyIfTrusted: true} : undefined], provider);
        } catch (error) {
            if (silent && error?.code === 4100) {
                return {accounts: []};
            }
            throw error;
        }
        return {accounts: refreshAccounts()};
    }

    async function standardDisconnect() {
        await callSolana("disconnect", []);
    }

    function callSolana(name, arguments_, provider = solanaProvider()) {
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

    const features = makeWalletStandardFeatures({
        connect: standardConnect,
        disconnect: standardDisconnect,
        on: standardOn,
        signAndSendTransaction: (...arguments_) => callSolana(
            "standardSignAndSendTransaction",
            arguments_
        ),
        signTransaction: (...arguments_) => callSolana(
            "standardSignTransaction",
            arguments_
        ),
        signMessage: (...arguments_) => callSolana("standardSignMessage", arguments_),
    });
    Object.defineProperties(solana, {
        standardOn: {value: standardOn},
        standardAccounts: {value: refreshAccounts},
        standardFeatures: {value: () => features},
        standardConnect: {value: standardConnect},
        standardDisconnect: {value: standardDisconnect},
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
        if (typeof nextEthereum.subscribeReadiness !== "function" ||
            typeof nextEthereum.withReadyState !== "function") {
            throw new TypeError("Ethereum target is invalid");
        }
        if (typeof nextSolana.provider.accountState !== "function" ||
            typeof nextSolana.provider.onAccountChange !== "function") {
            throw new TypeError("Solana account state is unavailable");
        }
        readAccount(nextSolana);
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
                bindAccountChanges();
                scheduleConnectReplay();
                return previous;
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
            wallet,
        });
        dispatchWalletStandardRegistrationEvent(registration);
        window.addEventListener(
            "wallet-standard:app-ready",
            event => registration(event.detail)
        );
        const host = window.navigator?.wallets;
        if (host == null) {
            window.navigator.wallets = [registration];
        } else if (typeof host.push === "function") {
            host.push(registration);
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
