// Copyright © 2023 Tokenary. All rights reserved.

const button = document.getElementById('tokenary-button');
var message = getPendingRequest();

if (message != null) {
    setupButton();
} else {
    browser.tabs.getCurrent(function(tab) {
        browser.runtime.sendMessage({subject: 'POPUP_APPEARED', tab: tab}).then((response) => {
            button.innerText = response;
        });
    });
}

button.addEventListener('click', () => {
    var request = message;
    const fresh = getPendingRequest();
    if (fresh != null) {
        request = fresh;
    }
    const query = encodeURIComponent(JSON.stringify(request)) + '";';
    browser.tabs.executeScript({
      code: 'window.location.href = "https://tokenary.io/extension?query=' + query
    });
    
    setTimeout( function() {
        window.close();
    }, 200);
    
    browser.runtime.sendMessage({subject: 'POPUP_DID_PROCEED', id: request.id});
});

function setupButton() {
    var title = "open the app";
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
                title = "connect\nwallet";
            }
            break;
    }

    button.innerText = title;
}

function getPendingRequest() {
    const bg = browser.extension.getBackgroundPage();
    if (bg != null) {
        return bg.pendingPopupRequest;
    } else {
        return null;
    }
}
