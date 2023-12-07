// Copyright © 2022 Tokenary. All rights reserved.

const isMobile = true; // TODO: setup from platform-specific content script

browser.runtime.onMessage.addListener((request, sender, sendResponse) => {
    if (request.subject === "POPUP_DID_PROCEED" && request.id === pendingPopupId) {
        pendingPopupId = null;
        pendingPopupRequest = null;
        sendPopupCancelResponse = null;
    } else if (request.subject === "POPUP_APPEARED") {
        didClickMobileExtensionButton(request.tab, sendResponse);
    } else if (request.subject === "message-to-wallet") {
        if (isMobile) {
            const name = request.message.name;
            if (name != "switchEthereumChain" && name != "addEthereumChain") {
                popupQueue.push({pendingPopupRequest: request.message, sendPopupCancelResponse: sendResponse});
                processPopupQueue();
            }
        }
        sendNativeMessage(request, sender, sendResponse);
    } else if (request.subject === "getResponse") { // TODO: test and update for ios
        browser.runtime.sendNativeMessage("mac.tokenary.io", request, function(response) {
            sendResponse(response);
            storeConfigurationIfNeeded(request.host, response);
            if (isMobile) {
                setTimeout( function() { processPopupQueue(); }, 500); // TODO: fix for v3
            }
        });
    } else if (request.subject === "getLatestConfiguration") {
        getLatestConfiguration(request.host).then(currentConfiguration => {
            sendResponse(currentConfiguration);
        });
    } else if (request.subject === "disconnect") {
        const provider = request.provider;
        const host = request.host;
        
        getLatestConfiguration(host).then(currentConfiguration => {
            const configurations = currentConfiguration.latestConfigurations;
            
            var indexToRemove = -1;
            for (var i = 0; i < configurations.length; i++) {
                if (configurations[i].provider == provider) {
                    indexToRemove = i;
                    break;
                }
            }
            if (indexToRemove > -1) {
                configurations.splice(indexToRemove, 1);
            }
            
            storeLatestConfiguration(host, configurations);
        });
    }
    return true;
});

function sendNativeMessage(request, sender, sendResponse) {
    browser.runtime.sendNativeMessage("mac.tokenary.io", request.message, function(response) {
        sendResponse(response);
        didCompleteRequest(request.message.id, sender.tab.id);
        storeConfigurationIfNeeded(request.host, response);
        if (isMobile) {
            setTimeout( function() { processPopupQueue(); }, 500); // TODO: fix for v3
        }
    });
}

function storeLatestConfiguration(host, configuration) {
    var latestArray = [];
    if (Array.isArray(configuration)) {
        latestArray = configuration;
        browser.storage.local.set({ [host]: latestArray });
    } else if ("provider" in configuration) {
        (async () => {
            const latest = await getLatestConfiguration(host);
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
            browser.storage.local.set({ [host]: latestArray });
        })();
    }
}

function getLatestConfiguration(host) {
    return new Promise((resolve) => {
        browser.storage.local.get(host).then(result => {
            const latest = result[host];
            let response = {};
            if (Array.isArray(latest)) {
                response.latestConfigurations = latest;
            } else if (typeof latest !== "undefined" && "provider" in latest) {
                response.latestConfigurations = [latest];
            } else {
                response.latestConfigurations = [];
            }
            resolve(response);
        }).catch(() => {
            resolve({ latestConfigurations: [] });
        });
    });
}

function storeConfigurationIfNeeded(host, response) {
    if (host.length > 0 && "configurationToStore" in response) {
        const configuration = response.configurationToStore;
        storeLatestConfiguration(host, configuration);
    }
}

function justShowApp() {
    const id = genId();
    const showAppMessage = {name: "justShowApp", id: id, provider: "unknown", body: {}, host: ""};
    browser.runtime.sendNativeMessage("mac.tokenary.io", showAppMessage);
}

browser.action.onClicked.addListener(function(tab) {
    const message = {didTapExtensionButton: true};
    browser.tabs.sendMessage(tab.id, message, function(host) {
        if (typeof host !== "undefined") {
            getLatestConfiguration(host).then(currentConfiguration => {
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

function didCompleteRequest(id, tabId) {
    if (isMobile) {
        browser.tabs.update(tabId, { active: true });
        const request = {id: id, subject: "didCompleteRequest"};
        browser.runtime.sendNativeMessage("mac.tokenary.io", request);
    }
}

// MARK: - iOS extension popup

// TODO: fix for v3
var pendingPopupRequest = null;
var pendingPopupId = null;
var sendPopupCancelResponse = null;
var popupQueue = [];

function processPopupQueue() {
    if (popupQueue.length && pendingPopupId == null) {
        const setupExistingSwitchAccountPopup = popupQueue[0].pendingPopupRequest.name == "switchAccount";
        
        if (!hasVisiblePopup() || setupExistingSwitchAccountPopup) {
            const next = popupQueue[0];
            popupQueue.shift();
            pendingPopupRequest = next.pendingPopupRequest;
            const id = pendingPopupRequest.id;
            pendingPopupId = id;
            sendPopupCancelResponse = next.sendPopupCancelResponse;
            
            if (!setupExistingSwitchAccountPopup) {
                browser.action.openPopup();
            }
            
            setTimeout( function() { pollPopupStatus(id); }, 1000); // TODO: fix for v3
        }
    }
}

function pollPopupStatus(id) {
    if (hasVisiblePopup() && pendingPopupId === id) {
        setTimeout( function() { pollPopupStatus(id); }, 1000); // TODO: fix for v3
    } else if (pendingPopupId === id) {
        pendingPopupId = null;
        didDismissPopup();
    }
}

function didDismissPopup() {
    cancelPopupRequest(pendingPopupRequest, sendPopupCancelResponse);
    pendingPopupRequest = null;
    sendPopupCancelResponse = null;
    
    if (popupQueue.length) {
        for (let item of popupQueue) {
            cancelPopupRequest(item.pendingPopupRequest, item.sendPopupCancelResponse);
        }
        popupQueue = [];
    }
}

function cancelPopupRequest(request, sendResponse) {
    const cancelResponse = {
        id: request.id,
        provider: request.provider,
        name: request.name,
        error: "canceled",
        subject: "cancelRequest",
    };
    browser.runtime.sendNativeMessage("mac.tokenary.io", cancelResponse);
    sendResponse(cancelResponse);
}

function didClickMobileExtensionButton(tab, sendResponse) {
    const message = {didTapExtensionButton: true};
    browser.tabs.sendMessage(tab.id, message, function(host) {
        if (typeof host !== "undefined") {
            getLatestConfiguration(host).then(currentConfiguration => {
                const latestConfigurations = currentConfiguration.latestConfigurations;
                if (Array.isArray(latestConfigurations) && latestConfigurations.length) {
                    sendResponse("switch\naccount");
                } else {
                    sendResponse("connect\nwallet");
                }
                
                const switchAccountMessage = {name: "switchAccount", id: genId(), provider: "unknown", body: currentConfiguration};
                browser.tabs.sendMessage(tab.id, switchAccountMessage);
            });
        }
    });
}

function hasVisiblePopup() {
    const popup = browser.extension.getViews({ type: 'popup' });
    if (popup.length === 0) {
        return false;
    } else if (popup.length > 0) {
        return true;
    }
}
