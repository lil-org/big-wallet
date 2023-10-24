// Copyright © 2023 Tokenary. All rights reserved.

const button = document.getElementById('tokenary-button');
const message = browser.extension.getBackgroundPage().pendingPopupRequest;

button.addEventListener('click', () => {
    const query = encodeURIComponent(JSON.stringify(message)) + '";';
    browser.tabs.executeScript({
      code: 'window.location.href = "https://tokenary.io/extension?query=' + query
    });
    
    setTimeout( function() {
        window.close();
    }, 200);
    
    browser.runtime.sendMessage({subject: 'POPUP_DID_PROCEED'});
});

var title = "proceed\nin tokenary";
switch (message.name) {
    case "signPersonalMessage":
    case "signMessage":
    case "signTypedMessage":
        title = "sign message\nin the app";
        break;
    case "signTransaction":
    case "signAndSendTransactions":
    case "signAllTransactions":
    case "signAndSendTransaction":
        title = "approve transaction\nin the app";
        break;
    case "requestAccounts":
    case "signIn":
    case "connect":
        title = "connect";
        break;
    case "switchAccount":
        const latestConfigurations = message.body.latestConfigurations;
        if (Array.isArray(latestConfigurations) && latestConfigurations.length) {
            title = "switch\naccount";
        } else {
            title = "connect\ntokenary";
        }
        break;
}

button.innerText = title;
