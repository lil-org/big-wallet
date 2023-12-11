// Copyright © 2022 Tokenary. All rights reserved.

const isMobile = true; // TODO: setup from platform-specific content script

browser.runtime.onMessage.addListener((request, sender, sendResponse) => {
    if (request.subject === "POPUP_PING") {
    } else if (request.subject === "POPUP_DID_PROCEED") {
        popupDidProceed(request.id);
    } else if (request.subject === "POPUP_APPEARED") {
        didAppearPopup(request.tab, sendResponse);
    } else if (request.subject === "message-to-wallet") {
        if (isMobile) {
            const name = request.message.name;
            if (name != "switchEthereumChain" && name != "addEthereumChain" && name != "switchAccount") {
                addToPopupQueue(request.message, sendResponse);
            }
        }
        sendNativeMessage(request, sender, sendResponse);
    } else if (request.subject === "getResponse") {
        browser.runtime.sendNativeMessage("mac.tokenary.io", request, function(response) {
            sendResponse(response);
            storeConfigurationIfNeeded(request.host, response);
            waitAndShowNextPopupIfNeeded(isMobile);
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
        waitAndShowNextPopupIfNeeded(isMobile);
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
    browser.tabs.sendMessage(tab.id, message, function(response) {
        if (typeof response !== "undefined" && typeof response.host !== "undefined") {
            getLatestConfiguration(response.host).then(currentConfiguration => {
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

function waitAndShowNextPopupIfNeeded(isMobile) {
    if (isMobile) {
        setTimeout(processPopupQueue, 420);
    }
}

function addToPopupQueue(popupRequest, sendCancelResponse) {
    storePopupRequest(popupRequest, sendCancelResponse);
    showPopupIfThereIsNoVisible(popupRequest.id);
}

function processPopupQueue() {
    const id = 42; // TODO: use actual popup id if there is one
    showPopupIfThereIsNoVisible(id);
}

function showPopupIfThereIsNoVisible(id) {
    if (!hasVisiblePopup()) {
        browser.action.openPopup();
        didShowPopup(id);
    }
}

function didShowPopup(id) {
    storeCurrentPopupId(id);
    setTimeout( function() { pollPopupStatus(id); }, 420);
}

function pollPopupStatus(id) {
    if (hasVisiblePopup()) {
        setTimeout( function() { pollPopupStatus(id); }, 420);
    } else {
        getCurrentPopupId().then(currentId => {
            if (id == currentId) {
                didDismissPopup();
            }
        });
    }
}

function popupDidProceed(id) {
    cleanupStoredPopup(id);
}

function didDismissPopup() {
    cleanupPopupsQueue();
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

function didAppearPopup(tab, sendResponse) {
    // TODO: process something if hasSomething — it was not neccesseraly an action button click
    const message = {didTapExtensionButton: true};
    browser.tabs.sendMessage(tab.id, message, function(response) {
        if (typeof response !== "undefined" && typeof response.host !== "undefined") {
            getLatestConfiguration(response.host).then(currentConfiguration => {
                const latestConfigurations = currentConfiguration.latestConfigurations;
                const switchAccountMessage = {
                    name: "switchAccount",
                    id: genId(),
                    provider: "unknown",
                    body: currentConfiguration,
                    host: response.host,
                    favicon: response.favicon
                };
                sendResponse(switchAccountMessage);
                didShowPopup(switchAccountMessage.id);
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
