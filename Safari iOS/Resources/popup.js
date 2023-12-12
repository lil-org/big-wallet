// Copyright © 2023 Tokenary. All rights reserved.

const button = document.getElementById('tokenary-button');
var message = {};

browser.tabs.getCurrent(tab => {
    browser.runtime.sendMessage({subject: 'POPUP_APPEARED', tab: tab}).then((response) => {
        message = response;
        setupButton();
    });
});

button.addEventListener('click', () => {
    const query = encodeURIComponent(JSON.stringify(message));
    browser.tabs.getCurrent((tab) => {
        if (tab) {
            browser.scripting.executeScript({
            target: { tabId: tab.id },
            func: (query) => { window.location.href = `https://tokenary.io/extension?query=${query}`; },
            args: [query]
            });
        }
    });
    browser.runtime.sendMessage({subject: 'POPUP_DID_PROCEED', id: message.id});
    setTimeout(window.close, 437);
    return true;
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
