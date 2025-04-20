// ∅ 2025 lil org
// Rewrite of index.js from trust-web3-provider.

"use strict";

import BigWalletEthereum from "./ethereum";
import ProviderRpcError from "./error";

window.bigwallet = {};
window.bigwallet.postMessage = (name, id, body, provider) => {
    const message = {name: name, id: id, provider: provider, body: body};
    window.postMessage({direction: "from-page-script", message: message}, "*");
};

window.bigwallet.disconnect = (provider) => {
    const disconnectRequest = {subject: "disconnect", provider: provider};
    window.postMessage(disconnectRequest, "*");
};

// - MARK: Ethereum

let provider = new BigWalletEthereum();
window.bigwallet.eth = provider;
window.ethereum = provider;
window.web3 = {currentProvider: provider};
window.metamask = provider;
window.dispatchEvent(new Event('ethereum#initialized'));

// MARK: EIP-6963

function announceProvider() {
    const info = {
        uuid: "08ac99d0-ec2b-4088-8599-c9f7eede344e",
        name: "Big Wallet",
        icon: 'data:image/svg+xml;base64,PHN2ZyB3aWR0aD0iMTAyNCIgaGVpZ2h0PSIxMDI0IiB2aWV3Qm94PSIwIDAgMTAyNCAxMDI0IiBmaWxsPSJub25lIiB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciPgo8ZyBjbGlwLXBhdGg9InVybCgjY2xpcDBfMzQwXzYwKSI+CjxwYXRoIGQ9Ik0xMjk4LjggNTEyLjRDMTI5OC44IDc4LjA4MzggOTQ2LjcxNiAtMjc0IDUxMi40IC0yNzRDNzguMDgzOCAtMjc0IC0yNzQgNzguMDgzOCAtMjc0IDUxMi40Qy0yNzQgOTQ2LjcxNiA3OC4wODM4IDEyOTguOCA1MTIuNCAxMjk4LjhDOTQ2LjcxNiAxMjk4LjggMTI5OC44IDk0Ni43MTYgMTI5OC44IDUxMi40WiIgZmlsbD0idXJsKCNwYWludDBfcmFkaWFsXzM0MF82MCkiLz4KPHBhdGggZD0iTTUxMi4zOTkgLTI2Ni4xMzNDOTQxLjc3NCAtMjY2LjEzMyAxMjkwLjk0IDgzLjAyODggMTI5MC45NCA1MTIuNDAzQzEyOTAuOTQgOTQxLjc3OCA5NDEuNzc0IDEyOTAuOTQgNTEyLjM5OSAxMjkwLjk0QzgzLjAyNDkgMTI5MC45NCAtMjY2LjEzNyA5NDEuNzc4IC0yNjYuMTM3IDUxMi40MDNDLTI2Ni4xMzcgODMuMDI4OCA4My4wMjQ5IC0yNjYuMTMzIDUxMi4zOTkgLTI2Ni4xMzNaIiBzdHJva2U9ImJsYWNrIiBzdHJva2Utb3BhY2l0eT0iMC4wNzUiLz4KPC9nPgo8ZGVmcz4KPHJhZGlhbEdyYWRpZW50IGlkPSJwYWludDBfcmFkaWFsXzM0MF82MCIgY3g9IjAiIGN5PSIwIiByPSIxIiBncmFkaWVudFVuaXRzPSJ1c2VyU3BhY2VPblVzZSIgZ3JhZGllbnRUcmFuc2Zvcm09InRyYW5zbGF0ZSg3NzEuMjQ4IDEwOS4wOTUpIHNjYWxlKDExODQuMTcpIj4KPHN0b3Agb2Zmc2V0PSIwLjE1NjIiIHN0b3AtY29sb3I9IiNDNkU2RjUiLz4KPHN0b3Agb2Zmc2V0PSIwLjM5NTgiIHN0b3AtY29sb3I9IiNBM0QyRjAiLz4KPHN0b3Agb2Zmc2V0PSIwLjcyOTIiIHN0b3AtY29sb3I9IiM1RjhBRTciLz4KPHN0b3Agb2Zmc2V0PSIwLjkwNjMiIHN0b3AtY29sb3I9IiMxRDQ5RTciLz4KPHN0b3Agb2Zmc2V0PSIxIiBzdG9wLWNvbG9yPSIjMTQzOEVCIi8+CjwvcmFkaWFsR3JhZGllbnQ+CjxjbGlwUGF0aCBpZD0iY2xpcDBfMzQwXzYwIj4KPHJlY3Qgd2lkdGg9IjEwMjQiIGhlaWdodD0iMTAyNCIgZmlsbD0id2hpdGUiLz4KPC9jbGlwUGF0aD4KPC9kZWZzPgo8L3N2Zz4K',
        rdns: "org.lil.wallet"
    };
    window.dispatchEvent(new CustomEvent("eip6963:announceProvider", { detail: Object.freeze({ info, provider }), }));
}

window.addEventListener("eip6963:requestProvider", function(event) { announceProvider(); });
announceProvider();

// - MARK: Process content script messages

window.addEventListener("message", function(event) {
    if (event.source == window && event.data && event.data.direction == "rpc-back") {
        provider.processBigWalletResponse(event.data.response.id, event.data.response);
    } else if (event.source == window && event.data && event.data.direction == "from-content-script") {
        const response = event.data.response;
        const id = event.data.id;
        
        if ("latestConfigurations" in response) {
            const name = "didLoadLatestConfiguration";
            var remainingProviders = new Set(["ethereum"]);
            
            for(let configurationResponse of response.latestConfigurations) {
                configurationResponse.name = name;
                deliverResponseToSpecificProvider(id, configurationResponse, configurationResponse.provider);
                remainingProviders.delete(configurationResponse.provider);
            }
            
            remainingProviders.forEach((provider) => {
                deliverResponseToSpecificProvider(id, {name: "didLoadLatestConfiguration"}, provider);
            });
        } else {
            deliverResponseToSpecificProvider(id, response, response.provider);
        }
    }
});

function deliverResponseToSpecificProvider(id, response, providerName) {
    switch (providerName) {
        case "ethereum":
            provider.processBigWalletResponse(id, response);
            break;
        case "multiple":
            response.bodies.forEach((body) => {
                body.id = id;
                body.name = response.name;
                deliverResponseToSpecificProvider(id, body, body.provider);
            });
            
            response.providersToDisconnect.forEach((providerName) => {
                switch (providerName) {
                    case "ethereum":
                        provider.externalDisconnect();
                        break;
                    default:
                        break;
                }
            });
            
            break;
        default:
            // pass unknown provider message to all providers
            provider.processBigWalletResponse(id, response);
    }
}
