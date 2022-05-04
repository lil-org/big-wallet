// Copyright © 2021 Tokenary. All rights reserved.
// Rewrite of index.js from trust-web3-provider.

"use strict";

import TokenaryEthereum from "./ethereum";
import TokenarySolana from "./solana";

window.tokenary = {};
window.tokenary.postMessage = (name, id, body, provider) => {
    const message = {name: name, id: id, provider: provider, body: body};
    window.postMessage({direction: "from-page-script", message: message}, "*");
};

window.ethereum = new TokenaryEthereum();
const ethereumHandler = {
    get(target, property) {
        return window.ethereum;
    }
}
window.web3 = new Proxy(window.ethereum, ethereumHandler);

window.solana = new TokenarySolana();
const solanaHandler = {
    get(target, property) {
        return window.solana;
    }
}
window.phantom = new Proxy(window.solana, solanaHandler);

window.addEventListener("message", function(event) {
    if (event.source == window && event.data && event.data.direction == "from-content-script") {
        const response = event.data.response;
        const id = event.data.id;
        switch (response.provider) {
            case "ethereum":
                window.ethereum.processTokenaryResponse(id, response);
                break;
            case "solana":
                window.solana.processTokenaryResponse(id, response);
                break;
            default:
                // pass unknown provider message to all providers 
                window.ethereum.processTokenaryResponse(id, response);
                window.solana.processTokenaryResponse(id, response);
        }
    }
});
