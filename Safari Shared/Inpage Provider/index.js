// ∅ 2024 lil org
// Rewrite of index.js from trust-web3-provider.

"use strict";

import TinyWalletEthereum from "./ethereum";
import ProviderRpcError from "./error";

window.tinywallet = {};
window.tinywallet.postMessage = (name, id, body, provider) => {
    const message = {name: name, id: id, provider: provider, body: body};
    window.postMessage({direction: "from-page-script", message: message}, "*");
};

window.tinywallet.disconnect = (provider) => {
    const disconnectRequest = {subject: "disconnect", provider: provider};
    window.postMessage(disconnectRequest, "*");
};

// - MARK: Ethereum

let provider = new TinyWalletEthereum();
window.tinywallet.eth = provider;
window.ethereum = provider;
window.web3 = {currentProvider: provider};
window.metamask = provider;
window.dispatchEvent(new Event('ethereum#initialized'));

// MARK: EIP-6963

function announceProvider() {
    const info = {
        uuid: "bcce26fb-e330-425c-9d21-43ed52e98fcf",
        name: "tiny wallet",
        icon: 'data:image/svg+xml;base64,PHN2ZyB3aWR0aD0iMjU2IiBoZWlnaHQ9IjI1NiIgdmlld0JveD0iMCAwIDI1NiAyNTYiIGZpbGw9Im5vbmUiIHhtbG5zPSJodHRwOi8vd3d3LnczLm9yZy8yMDAwL3N2ZyI+CjxyZWN0IHdpZHRoPSIyNTYiIGhlaWdodD0iMjU2IiBmaWxsPSJ3aGl0ZSIvPgo8cGF0aCBkPSJNMjA5Ljc1IDEyOEMyMDkuNzUgODIuODUwOCAxNzMuMTQ5IDQ2LjI1IDEyOCA0Ni4yNUM4Mi44NTA4IDQ2LjI1IDQ2LjI1IDgyLjg1MDggNDYuMjUgMTI4QzQ2LjI1IDE3My4xNDkgODIuODUwOCAyMDkuNzUgMTI4IDIwOS43NUMxNzMuMTQ5IDIwOS43NSAyMDkuNzUgMTczLjE0OSAyMDkuNzUgMTI4WiIgZmlsbD0idXJsKCNwYWludDBfcmFkaWFsXzIwMzRfMjIpIi8+CjxwYXRoIGQ9Ik0xMjguMDAxIDQ3LjA2NzRDMTcyLjYzNiA0Ny4wNjc0IDIwOC45MzMgODMuMzY0NCAyMDguOTMzIDEyOEMyMDguOTMzIDE3Mi42MzUgMTcyLjYzNiAyMDguOTMyIDEyOC4wMDEgMjA4LjkzMkM4My4zNjU0IDIwOC45MzIgNDcuMDY4NCAxNzIuNjM1IDQ3LjA2ODQgMTI4QzQ3LjA2ODQgODMuMzY0NCA4My4zNjU0IDQ3LjA2NzQgMTI4LjAwMSA0Ny4wNjc0WiIgc3Ryb2tlPSJibGFjayIgc3Ryb2tlLW9wYWNpdHk9IjAuMDc1Ii8+CjxkZWZzPgo8cmFkaWFsR3JhZGllbnQgaWQ9InBhaW50MF9yYWRpYWxfMjAzNF8yMiIgY3g9IjAiIGN5PSIwIiByPSIxIiBncmFkaWVudFVuaXRzPSJ1c2VyU3BhY2VPblVzZSIgZ3JhZGllbnRUcmFuc2Zvcm09InRyYW5zbGF0ZSgxNTQuOTA5IDg2LjA3NDUpIHNjYWxlKDEyMy4xKSI+CjxzdG9wIG9mZnNldD0iMC4xNTYyIiBzdG9wLWNvbG9yPSIjQzZFNkY1Ii8+CjxzdG9wIG9mZnNldD0iMC4zOTU4IiBzdG9wLWNvbG9yPSIjQTNEMkYwIi8+CjxzdG9wIG9mZnNldD0iMC43MjkyIiBzdG9wLWNvbG9yPSIjNUY4QUU3Ii8+CjxzdG9wIG9mZnNldD0iMC45MDYzIiBzdG9wLWNvbG9yPSIjMUQ0OUU3Ii8+CjxzdG9wIG9mZnNldD0iMSIgc3RvcC1jb2xvcj0iIzE0MzhFQiIvPgo8L3JhZGlhbEdyYWRpZW50Pgo8L2RlZnM+Cjwvc3ZnPgo=',
        rdns: "org.lil.wallet"
    };
    window.dispatchEvent(new CustomEvent("eip6963:announceProvider", { detail: Object.freeze({ info, provider }), }));
}

window.addEventListener("eip6963:requestProvider", function(event) { announceProvider(); });
announceProvider();

// - MARK: Process content script messages

window.addEventListener("message", function(event) {
    if (event.source == window && event.data && event.data.direction == "rpc-back") {
        provider.processTinyWalletResponse(event.data.response.id, event.data.response);
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
            provider.processTinyWalletResponse(id, response);
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
            provider.processTinyWalletResponse(id, response);
    }
}
