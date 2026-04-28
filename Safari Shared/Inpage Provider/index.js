// ∅ 2026 lil org
// Rewrite of index.js from trust-web3-provider.

"use strict";

import BigWalletEthereum from "./ethereum";
import BigWalletSolana from "./solana";

window.bigwallet = {};
window.bigwallet.postMessage = (name, id, body, provider) => {
    const message = {name: name, id: id, provider: provider, body: body};
    window.postMessage({direction: "from-page-script", message: message}, "*");
};

window.bigwallet.disconnect = (provider) => {
    const disconnectRequest = {subject: "disconnect", provider: provider};
    window.postMessage(disconnectRequest, "*");
};

const bigWalletIcon = 'data:image/svg+xml;base64,PHN2ZyB3aWR0aD0iMTAyNCIgaGVpZ2h0PSIxMDI0IiB2aWV3Qm94PSIwIDAgMTAyNCAxMDI0IiBmaWxsPSJub25lIiB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciPgo8cmVjdCB3aWR0aD0iMTAyNCIgaGVpZ2h0PSIxMDI0IiBmaWxsPSJ3aGl0ZSIvPgo8cGF0aCBkPSJNODI3IDUxMkM4MjcgMzM4LjAzMSA2ODUuOTY5IDE5NyA1MTIgMTk3QzMzOC4wMzEgMTk3IDE5NyAzMzguMDMxIDE5NyA1MTJDMTk3IDY4NS45NjkgMzM4LjAzMSA4MjcgNTEyIDgyN0M2ODUuOTY5IDgyNyA4MjcgNjg1Ljk2OSA4MjcgNTEyWiIgZmlsbD0idXJsKCNwYWludDBfbGluZWFyXzFfMTQpIi8+CjxkZWZzPgo8bGluZWFyR3JhZGllbnQgaWQ9InBhaW50MF9saW5lYXJfMV8xNCIgeDE9IjUxMiIgeTE9IjE5NyIgeDI9IjUxMiIgeTI9IjgyNyIgZ3JhZGllbnRVbml0cz0idXNlclNwYWNlT25Vc2UiPgo8c3RvcCBzdG9wLWNvbG9yPSIjNjJDQ0Y5Ii8+CjxzdG9wIG9mZnNldD0iMSIgc3RvcC1jb2xvcj0iIzAwN0FGRiIvPgo8L2xpbmVhckdyYWRpZW50Pgo8L2RlZnM+Cjwvc3ZnPgo=';

// - MARK: Ethereum

const ethereumProvider = new BigWalletEthereum();
window.bigwallet.eth = ethereumProvider;
window.ethereum = ethereumProvider;
window.web3 = {currentProvider: ethereumProvider};
window.metamask = ethereumProvider;
window.dispatchEvent(new Event('ethereum#initialized'));

// - MARK: Solana

const solanaProvider = new BigWalletSolana();
window.bigwallet.solana = solanaProvider;
window.solana = solanaProvider;
window.phantom = window.phantom || {};
window.phantom.solana = solanaProvider;
solanaProvider.registerWalletStandard({ icon: bigWalletIcon });
window.dispatchEvent(new Event("solana#initialized"));

const providers = {
    ethereum: ethereumProvider,
    solana: solanaProvider,
};
const providerNames = Object.keys(providers);
const supportedProviderNames = new Set(providerNames);

// MARK: EIP-6963

function announceProvider() {
    const info = {
        uuid: "08ac99d0-ec2b-4088-8599-c9f7eede344e",
        name: "Big Wallet",
        icon: bigWalletIcon,
        rdns: "org.lil.wallet"
    };
    window.dispatchEvent(new CustomEvent("eip6963:announceProvider", { detail: Object.freeze({ info, provider: ethereumProvider }), }));
}

window.addEventListener("eip6963:requestProvider", function(event) { announceProvider(); });
announceProvider();

// - MARK: Process content script messages

window.addEventListener("message", function(event) {
    if (event.source == window && event.data && event.data.direction == "rpc-back") {
        ethereumProvider.processBigWalletResponse(event.data.response.id, event.data.response);
    } else if (event.source == window && event.data && event.data.direction == "from-content-script") {
        const response = event.data.response;
        const id = event.data.id;
        
        if ("latestConfigurations" in response) {
            const providerConfigurations = latestConfigurationsByProvider(response.latestConfigurations);
            const remainingProviders = new Set(providerNames);
            
            providerConfigurations.forEach((configurationResponse, providerName) => {
                deliverResponseToSpecificProvider(id, configurationResponse, providerName);
                remainingProviders.delete(providerName);
            });
            
            remainingProviders.forEach((provider) => {
                deliverResponseToSpecificProvider(id, {name: "didLoadLatestConfiguration"}, provider);
            });
        } else {
            deliverResponseToSpecificProvider(id, response, response.provider);
        }
    }
});

function deliverResponseToSpecificProvider(id, response, providerName) {
    const provider = providers[providerName];
    if (provider) {
        provider.processBigWalletResponse(id, response);
        return;
    }

    switch (providerName) {
        case "multiple":
            response.bodies.forEach((body) => {
                deliverResponseToSpecificProvider(id, {
                    ...body,
                    id: id,
                    name: response.name,
                }, body.provider);
            });
            
            response.providersToDisconnect.forEach((providerName) => {
                const providerToDisconnect = providers[providerName];
                if (providerToDisconnect) {
                    providerToDisconnect.externalDisconnect();
                }
            });
            
            break;
        default:
            // Preserve the legacy single-provider fallback for responses that
            // do not match a known provider without spraying them into Solana.
            ethereumProvider.processBigWalletResponse(id, response);
    }
}

function latestConfigurationsByProvider(latestConfigurations) {
    const configurations = new Map();
    if (!Array.isArray(latestConfigurations)) {
        return configurations;
    }

    latestConfigurations.forEach((configuration) => {
        if (!configuration || typeof configuration !== "object") {
            return;
        }

        const providerName = configuration.provider;
        if (!supportedProviderNames.has(providerName)) {
            return;
        }

        configurations.set(providerName, {
            ...configuration,
            name: "didLoadLatestConfiguration",
        });
    });

    return configurations;
}
