// Copyright © 2022 Tokenary. All rights reserved.

browser.runtime.onMessage.addListener((request, sender, sendResponse) => {
    if (request.subject === "message-to-wallet") {
        browser.runtime.sendNativeMessage("mac.tokenary.io", request.message, function(response) {
            sendResponse(response);
            browser.tabs.update(sender.tab.id, { active: true });
            didCompleteRequest(request.message.id);
            storeConfigurationIfNeeded(request.host, response);
        });
    } else if (request.subject === "getResponse") {
        browser.runtime.sendNativeMessage("mac.tokenary.io", request, function(response) {
            sendResponse(response);
            storeConfigurationIfNeeded(request.host, response);
        });
    } else if (request.subject === "getLatestConfiguration") {
        getLatestConfiguration(request.host, sendResponse);
    }
    return true;
});

var latestConfigurations = {};
var didReadLatestConfigurations = false;

function respondWithLatestConfiguration(host, sendResponse) {
    var response = {};
    
    const latest = latestConfigurations[host];
    if (typeof latest !== "undefined") {
        response = latest;
    }
    
    response.name = "didLoadLatestConfiguration";
    sendResponse(response);
}

function storeLatestConfiguration(host, configuration) {
    // TODO: merge with current value if there is a different provider
    
    latestConfigurations[host] = configuration;
    browser.storage.local.set( {[host]: configuration});
    
    console.log("did store new latest configuration", host, configuration);
    console.log(latestConfigurations);
}

function getLatestConfiguration(host, sendResponse) {
    if (didReadLatestConfigurations) {
        respondWithLatestConfiguration(host, sendResponse);
        return;
    }
    
    const storageItem = browser.storage.local.get();
    storageItem.then((storage) => {
        latestConfigurations = storage;
        didReadLatestConfigurations = true;
        respondWithLatestConfiguration(host, sendResponse);
    });
}

function storeConfigurationIfNeeded(host, response) {
    if (host.length > 0 && "configurationToStore" in response) {
        const configuration = response.configurationToStore;
        
        if (didReadLatestConfigurations) {
            storeLatestConfiguration(host, configuration);
            return;
        }
        
        const storageItem = browser.storage.local.get();
        storageItem.then((storage) => {
            latestConfigurations = storage;
            didReadLatestConfigurations = true;
            storeLatestConfiguration(host, configuration);
        });
    }
}

browser.browserAction.onClicked.addListener(function(tab) {
    const message = {didTapExtensionButton: true};
    browser.tabs.sendMessage(tab.id, message);
    if (tab.url == "" && tab.pendingUrl == "") {
        const id = genId();
        const showAppMessage = {name: "justShowApp", id: id, provider: "unknown", body: {}, host: ""};
        browser.runtime.sendNativeMessage("mac.tokenary.io", showAppMessage);
    }
});

function genId() {
    return new Date().getTime() + Math.floor(Math.random() * 1000);
}
