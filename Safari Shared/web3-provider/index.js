// Copyright © 2021 Tokenary. All rights reserved.
// Rewrite of index.js from trust-web3-provider.

"use strict";

import TokenaryWeb3Provider from "./ethereum";

window.tokenary = {Provider: TokenaryWeb3Provider, postMessage: null};

(function() {
    var config = {address: "", chainId: "0x1", rpcUrl: "https://mainnet.infura.io/v3/3f99b6096fda424bbb26e17866dcddfc"};
    window.ethereum = new tokenary.Provider(config);
    
    const handler = {
        get(target, property) {
            return window.ethereum;
        }
    }
    window.web3 = new Proxy(window.ethereum, handler);
    
    tokenary.postMessage = (jsonString) => {
        window.postMessage({direction: "from-page-script", message: jsonString}, "*");
    };
})();

window.addEventListener("message", function(event) {
    if (event.source == window && event.data && event.data.direction == "from-content-script") {
        const response = event.data.response;
        
        if (response.name == "didLoadLatestConfiguration") {
            window.ethereum.didGetLatestConfiguration = true;
            if (response.chainId) {
                window.ethereum.updateAccount(response.name, response.results, response.chainId, response.rpcURL);
            }
            
            for(let payload of window.ethereum.pendingPayloads) {
                window.ethereum._processPayload(payload);
            }
            
            window.ethereum.pendingPayloads = [];
            return;
        }
        
        if ("result" in response) {
            window.ethereum.sendResponse(event.data.id, response.result);
        } else if ("results" in response) {
            if (response.name == "switchEthereumChain" || response.name == "addEthereumChain") {
                // Calling it before sending response matters for some dapps
                window.ethereum.updateAccount(response.name, response.results, response.chainId, response.rpcURL);
            }
            if (response.name != "switchAccount") {
                window.ethereum.sendResponse(event.data.id, response.results);
            }
            if (response.name == "requestAccounts" || response.name == "switchAccount") {
                // Calling it after sending response matters for some dapps
                window.ethereum.updateAccount(response.name, response.results, response.chainId, response.rpcURL);
            }
        } else if ("error" in response) {
            window.ethereum.sendError(event.data.id, response.error);
        }
    }
});
