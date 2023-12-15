// Copyright © 2023 Tokenary. All rights reserved.

browser.runtime.onMessage.addListener((request, sender, sendResponse) => {
    if (request.subject === "message-to-wallet") {
        sendNativeMessage(request, sender, sendResponse);
        if (request.isMobile) {
            const name = request.message.name;
            if (name != "switchEthereumChain" && name != "addEthereumChain") {
                mobileRedirectFor(request.message);
            }
        }
    } else if (request.subject === "getResponse") {
        browser.runtime.sendNativeMessage("mac.tokenary.io", request).then(response => {
            if (typeof response !== "undefined") {
                sendResponse(response);
                storeConfigurationIfNeeded(request.host, response);
            }
        }).catch(() => {});
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
    browser.runtime.sendNativeMessage("mac.tokenary.io", request.message).then(response => {
        if (typeof response !== "undefined") {
            sendResponse(response);
            storeConfigurationIfNeeded(request.host, response);
        }
    }).catch(() => {});
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
    browser.runtime.sendNativeMessage("mac.tokenary.io", showAppMessage).catch(() => {});
}

browser.action.onClicked.addListener(tab => {
    const message = {didTapExtensionButton: true};
    browser.tabs.sendMessage(tab.id, message).then(response => {
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
    return true;
});

// MARK: - mobile redirect

function mobileRedirectFor(request) {
    const query = encodeURIComponent(JSON.stringify(request));
    browser.tabs.getCurrent((tab) => {
        if (tab) {
            browser.scripting.executeScript({
                target: { tabId: tab.id },
                func: (query) => {
                    window.location.href = `https://tokenary.io/extension?query=${query}`;
                },
                args: [query]
            });
        }
    });
}

// MARK: - helpers

function genId() {
    return new Date().getTime() + Math.floor(Math.random() * 1000);
}
