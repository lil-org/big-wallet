// ∅ 2024 lil org
// Rewrite of index.js from trust-web3-provider.

"use strict";

import TokenaryEthereum from "./ethereum";
import ProviderRpcError from "./error";

window.tokenary = {};
window.tokenary.postMessage = (name, id, body, provider) => {
    const message = {name: name, id: id, provider: provider, body: body};
    window.postMessage({direction: "from-page-script", message: message}, "*");
};

window.tokenary.disconnect = (provider) => {
    const disconnectRequest = {subject: "disconnect", provider: provider};
    window.postMessage(disconnectRequest, "*");
};

// - MARK: Ethereum

let provider = new TokenaryEthereum();
window.tokenary.eth = provider;
window.ethereum = provider;
window.web3 = {currentProvider: provider};
window.metamask = provider;
window.dispatchEvent(new Event('ethereum#initialized'));

// MARK: EIP-6963

function announceProvider() {
    const info = {
        uuid: "f9058af0-b501-43c4-bd7d-b43f83244681",
        name: "tokenary",
        icon: 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAxMTAgMTEwIj48ZGVmcz48cmFkaWFsR3JhZGllbnQgaWQ9Imd6ciIgZ3JhZGllbnRUcmFuc2Zvcm09InRyYW5zbGF0ZSg2Ni40NTc4IDI0LjM1NzUpIHNjYWxlKDc1LjI5MDgpIiBncmFkaWVudFVuaXRzPSJ1c2VyU3BhY2VPblVzZSIgcj0iMSIgY3g9IjAiIGN5PSIwJSI+PHN0b3Agb2Zmc2V0PSIxNS42MiUiIHN0b3AtY29sb3I9ImhzbCgyMDAsIDcxJSwgODclKSIgLz48c3RvcCBvZmZzZXQ9IjM5LjU4JSIgc3RvcC1jb2xvcj0iaHNsKDIwMywgNzIlLCA3OSUpIiAvPjxzdG9wIG9mZnNldD0iNzIuOTIlIiBzdG9wLWNvbG9yPSJoc2woMjIxLCA3NCUsIDY0JSkiIC8+PHN0b3Agb2Zmc2V0PSI5MC42MyUiIHN0b3AtY29sb3I9ImhzbCgyMjcsIDgxJSwgNTElKSIgLz48c3RvcCBvZmZzZXQ9IjEwMCUiIHN0b3AtY29sb3I9ImhzbCgyMzAsIDg0JSwgNTAlKSIgLz48L3JhZGlhbEdyYWRpZW50PjwvZGVmcz48ZyB0cmFuc2Zvcm09InRyYW5zbGF0ZSg1LDUpIj48cGF0aCBkPSJNMTAwIDUwQzEwMCAyMi4zODU4IDc3LjYxNDIgMCA1MCAwQzIyLjM4NTggMCAwIDIyLjM4NTggMCA1MEMwIDc3LjYxNDIgMjIuMzg1OCAxMDAgNTAgMTAwQzc3LjYxNDIgMTAwIDEwMCA3Ny42MTQyIDEwMCA1MFoiIGZpbGw9InVybCgjZ3pyKSIgLz48cGF0aCBzdHJva2U9InJnYmEoMCwwLDAsMC4wNzUpIiBmaWxsPSJ0cmFuc3BhcmVudCIgc3Ryb2tlLXdpZHRoPSIxIiBkPSJNNTAsMC41YzI3LjMsMCw0OS41LDIyLjIsNDkuNSw0OS41Uzc3LjMsOTkuNSw1MCw5OS41UzAuNSw3Ny4zLDAuNSw1MFMyMi43LDAuNSw1MCwwLjV6IiAvPjwvZz48L3N2Zz4=',
        rdns: "io.tokenary"
    };
    window.dispatchEvent(new CustomEvent("eip6963:announceProvider", { detail: Object.freeze({ info, provider }), }));
}

window.addEventListener("eip6963:requestProvider", function(event) { announceProvider(); });
announceProvider();

// - MARK: Process content script messages

window.addEventListener("message", function(event) {
    if (event.source == window && event.data && event.data.direction == "rpc-back") {
        provider.processTokenaryResponse(event.data.response.id, event.data.response);
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
            provider.processTokenaryResponse(id, response);
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
            provider.processTokenaryResponse(id, response);
    }
}
