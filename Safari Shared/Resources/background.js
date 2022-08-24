// Copyright © 2022 Tokenary. All rights reserved.

browser.runtime.onMessage.addListener((request, sender, sendResponse) => {
    if (request.subject === "message-to-wallet") {
        sendNativeMessage(request, sender, sendResponse);
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

function sendNativeMessage(request, sender, sendResponse) {
    browser.runtime.sendNativeMessage("mac.tokenary.io", request.message, function(response) {
        sendResponse(response);
        didCompleteRequest(request.message.id, sender.tab.id);
        storeConfigurationIfNeeded(request.host, response);
    });
}

function respondWithLatestConfiguration(host, sendResponse) {
    var response = {};
    const latest = latestConfigurations[host];
    
    if (Array.isArray(latest)) {
        response.latestConfigurations = latest;
    } else if (typeof latest !== "undefined" && "provider" in latest) {
        response.latestConfigurations = [latest];
    } else {
        response.latestConfigurations = [];
    }
    
    sendResponse(response);
}

function storeLatestConfiguration(host, configuration) {
    var latestArray = [];
    
    if (Array.isArray(configuration)) {
        latestArray = configuration;
    } else if ("provider" in configuration) {
        const latest = latestConfigurations[host];
        
        if (Array.isArray(latest)) {
            latestArray = latest;
        } else if (typeof latest !== "undefined" && "provider" in latest) {
            latestArray = [latest];
        }
        
        var shouldAdd = true;
        for (var i = 0; i < latestArray.length; i++) {
            if (latestArray[i].provider == configuration.provider) {
                latestArray[i] = configuration;
                shouldAdd = false;
                break;
            }
        }
        
        if (shouldAdd) {
            latestArray.push(configuration);
        }
    }
    
    latestConfigurations[host] = latestArray;
    browser.storage.local.set( {[host]: latestArray});
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

function justShowApp() {
    const id = genId();
    const showAppMessage = {name: "justShowApp", id: id, provider: "unknown", body: {}, host: ""};
    browser.runtime.sendNativeMessage("mac.tokenary.io", showAppMessage);
}

browser.browserAction.onClicked.addListener(function(tab) {
    const message = {didTapExtensionButton: true};
    browser.tabs.sendMessage(tab.id, message, function(host) {
        if (typeof host !== "undefined") {
            getLatestConfiguration(host, function(currentConfiguration) {
                const switchAccountMessage = {name: "switchAccount", id: genId(), provider: "unknown", body: currentConfiguration};
                browser.tabs.sendMessage(tab.id, switchAccountMessage);
            });
        } else {
            justShowApp();
        }
    });
    
    if (tab.url == "" && tab.pendingUrl == "") {
        justShowApp();
    }
});

function genId() {
    return new Date().getTime() + Math.floor(Math.random() * 1000);
}
