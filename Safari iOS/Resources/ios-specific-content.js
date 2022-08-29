// Copyright © 2022 Tokenary. All rights reserved.

function didChangeVisibility() {
    if (document.visibilityState === 'visible' && document.pendingRequestsIds.size != 0) {
        document.pendingRequestsIds.forEach(id => {
            const request = {id: id, subject: "getResponse", host: window.location.host};
            browser.runtime.sendMessage(request).then((response) => {
                sendToInpage(response, id);
            });
        });
    }
}

document.addEventListener('visibilitychange', didChangeVisibility);

function platformSpecificProcessMessage(message) {
    if (message.provider == "ethereum" && (message.name == "switchEthereumChain" || message.name == "addEthereumChain")) {
        return;
    } else {
        var title = "Proceed in Tokenary";
        switch (message.name) {
            case "signPersonalMessage":
            case "signMessage":
            case "signTypedMessage":
                title = "Sign Message in Tokenary";
                break;
            case "signTransaction":
            case "signAndSendTransactions":
            case "signAllTransactions":
            case "signAndSendTransaction":
                title = "Approve Transaction in Tokenary";
                break;
            case "requestAccounts":
            case "signIn":
            case "connect":
                title = "Connect Wallet";
                break;
            case "switchAccount":
                const latestConfigurations = message.body.latestConfigurations;
                if (Array.isArray(latestConfigurations) && latestConfigurations.length) {
                    title = "Switch Account or Disconnect";
                } else {
                    title = "Connect Wallet";
                }
                break;
        }
        
        const response = {overlayConfiguration: {request: message, title: title}};
        window.postMessage({direction: "from-content-script", response: response, id: message.id}, "*");
        
    }
}
