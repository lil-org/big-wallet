// Copyright © 2021 Tokenary. All rights reserved.
// Rewrite of index.js from trust-web3-provider.

"use strict";

import TokenaryEthereum from "./ethereum";
import TokenarySolana from "./solana";
import TokenaryNear from "./near";

window.tokenary = {};
window.tokenary.postMessage = (name, id, body, provider) => {
    const message = {name: name, id: id, provider: provider, body: body};
    window.postMessage({direction: "from-page-script", message: message}, "*");
};

// - MARK: Ethereum

window.ethereum = new TokenaryEthereum();
window.web3 = {currentProvider: window.ethereum};
window.metamask = window.ethereum;
window.dispatchEvent(new Event('ethereum#initialized'));

// - MARK: Solana

window.solana = new TokenarySolana();
window.tokenarySolana = window.solana;
window.phantom = {solana: window.solana};
window.dispatchEvent(new Event("solana#initialized"));

// - MARK: Near

window.near = new TokenaryNear();
window.sender = window.near;
window.dispatchEvent(new Event("near#initialized"));

// - MARK: Process content script messages

window.addEventListener("message", function(event) {
    if (event.source == window && event.data && event.data.direction == "from-content-script") {
        const response = event.data.response;
        const id = event.data.id;
        
        if ("latestConfigurations" in response) {
            const name = "didLoadLatestConfiguration";
            var remainingProviders = new Set(["ethereum", "solana", "near"]);
            
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

function deliverResponseToSpecificProvider(id, response, provider) {
    switch (provider) {
        case "ethereum":
            window.ethereum.processTokenaryResponse(id, response);
            break;
        case "solana":
            window.solana.processTokenaryResponse(id, response);
            break;
        case "near":
            window.near.processTokenaryResponse(id, response);
            break;
        case "multiple":
            response.bodies.forEach((body) => {
                body.id = id;
                body.name = response.name;
                deliverResponseToSpecificProvider(id, body, body.provider);
            });
            
            response.providersToDisconnect.forEach((provider) => {
                switch (provider) {
                    case "ethereum":
                        window.ethereum.externalDisconnect();
                        break;
                    case "solana":
                        window.solana.externalDisconnect();
                        break;
                    case "near":
                        window.near.externalDisconnect();
                        break;
                    default:
                        break;
                }
            });
            
            break;
        default:
            // pass unknown provider message to all providers
            window.ethereum.processTokenaryResponse(id, response);
            window.solana.processTokenaryResponse(id, response);
            window.near.processTokenaryResponse(id, response);
    }
}
