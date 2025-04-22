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
        icon: 'data:image/svg+xml;base64,PHN2ZyB3aWR0aD0iMTAyNCIgaGVpZ2h0PSIxMDI0IiB2aWV3Qm94PSIwIDAgMTAyNCAxMDI0IiBmaWxsPSJub25lIiB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciPgo8cmVjdCB3aWR0aD0iMTAyNCIgaGVpZ2h0PSIxMDI0IiBmaWxsPSJ3aGl0ZSIvPgo8cGF0aCBkPSJNODU0IDUxMkM4NTQgMzIzLjExOSA3MDAuODgxIDE3MCA1MTIgMTcwQzMyMy4xMTkgMTcwIDE3MCAzMjMuMTE5IDE3MCA1MTJDMTcwIDcwMC44ODEgMzIzLjExOSA4NTQgNTEyIDg1NEM3MDAuODgxIDg1NCA4NTQgNzAwLjg4MSA4NTQgNTEyWiIgZmlsbD0idXJsKCNwYWludDBfcmFkaWFsXzM0MF82MCkiLz4KPGRlZnM+CjxyYWRpYWxHcmFkaWVudCBpZD0icGFpbnQwX3JhZGlhbF8zNDBfNjAiIGN4PSIwIiBjeT0iMCIgcj0iMSIgZ3JhZGllbnRVbml0cz0idXNlclNwYWNlT25Vc2UiIGdyYWRpZW50VHJhbnNmb3JtPSJ0cmFuc2xhdGUoNjI0LjU3MSAzMzYuNjA1KSBzY2FsZSg1MTQuOTg5KSI+CjxzdG9wIG9mZnNldD0iMC4xNTYyIiBzdG9wLWNvbG9yPSIjQzZFNkY1Ii8+CjxzdG9wIG9mZnNldD0iMC4zOTU4IiBzdG9wLWNvbG9yPSIjQTNEMkYwIi8+CjxzdG9wIG9mZnNldD0iMC43MjkyIiBzdG9wLWNvbG9yPSIjNUY4QUU3Ii8+CjxzdG9wIG9mZnNldD0iMC45MDYzIiBzdG9wLWNvbG9yPSIjMUQ0OUU3Ii8+CjxzdG9wIG9mZnNldD0iMSIgc3RvcC1jb2xvcj0iIzE0MzhFQiIvPgo8L3JhZGlhbEdyYWRpZW50Pgo8L2RlZnM+Cjwvc3ZnPgo=',
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
