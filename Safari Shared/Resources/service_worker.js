// Copyright © 2023 Tokenary. All rights reserved.

function handleOnMessage(request, sender, sendResponse) {
    if (request.subject === "message-to-wallet") {
        var mobileRedirect = false;
        if (request.isMobile) {
            const name = request.message.name;
            if (name != "switchEthereumChain" && name != "addEthereumChain") {
                mobileRedirect = true;
            }
        }
        
        browser.runtime.sendNativeMessage("mac.tokenary.io", request.message).then(response => {
            if (typeof response !== "undefined") {
                sendResponse(response);
                storeConfigurationIfNeeded(request.host, response);
            } else {
                if (!mobileRedirect) {
                    sendResponse();
                }
            }
        }).catch(() => {
            if (!mobileRedirect) {
                sendResponse();
            }
        });
        
        if (mobileRedirect) {
            mobileRedirectFor(request, sendResponse);
        }
    } else if (request.subject === "getResponse") {
        browser.runtime.sendNativeMessage("mac.tokenary.io", request).then(response => {
            if (typeof response !== "undefined") {
                sendResponse(response);
                storeConfigurationIfNeeded(request.host, response);
            } else { sendResponse(); }
        }).catch(() => { sendResponse(); });
    } else if (request.subject === "getLatestConfiguration") {
        getLatestConfiguration(request.host).then(currentConfiguration => {
            sendResponse(currentConfiguration);
        }).catch(() => { sendResponse(); });
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
            sendResponse();
        }).catch(() => { sendResponse(); });
    } else {
        sendResponse();
    }
    return true;
}

function storeLatestConfiguration(host, configuration) {
    var latestArray = [];
    if (Array.isArray(configuration)) {
        latestArray = configuration;
        browser.storage.local.set({ [host]: latestArray }).then(() => {}).catch(() => {});
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
            browser.storage.local.set({ [host]: latestArray }).then(() => {}).catch(() => {});
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

function onBeforeExtensionPageNavigation(details) {
    if (details.url.includes("tokenary.io/extension?query=")) {
        const queryStringIndex = details.url.indexOf("?query=") + 7;
        const encodedQuery = details.url.substring(queryStringIndex);
        browser.tabs.update(details.tabId, { url: "tokenary://safari?request=" + encodedQuery });
    }
}

function justShowApp() {
    const id = genId();
    const showAppMessage = {name: "justShowApp", id: id, provider: "unknown", body: {}, host: ""};
    browser.runtime.sendNativeMessage("mac.tokenary.io", showAppMessage).then(() => {}).catch(() => {});
}

function handleOnClick(tab) {
    const message = {didTapExtensionButton: true};
    browser.tabs.sendMessage(tab.id, message).then(response => {
        if (typeof response !== "undefined" && "host" in response) {
            getLatestConfiguration(response.host).then(currentConfiguration => {
                const switchAccountMessage = {name: "switchAccount", id: genId(), provider: "unknown", body: currentConfiguration};
                browser.tabs.sendMessage(tab.id, switchAccountMessage).then(() => {}).catch(() => {});
            });
        } else {
            justShowApp();
        }
    }).catch(() => {});
    
    if (tab.url == "" && tab.pendingUrl == "") {
        justShowApp();
    }
}

// MARK: - mobile redirect

function mobileRedirectFor(request, sendResponse) {
    const query = encodeURIComponent(JSON.stringify(request.message));
    const shouldConfirm = request.message.name == "requestAccounts" && request.pageRequiresConfirmation;
    browser.tabs.getCurrent((tab) => {
        if (tab) {
            if (shouldConfirm) {
                const confirmationText = request.message.host + " | connect wallet";
                browser.tabs.executeScript(tab.id, {
                    code: `
                        var query = '` + query + `';
                        var confirmationText = '` + confirmationText + `';
                        var id = '` + request.message.id + `';
                        if (confirm(confirmationText)) {
                            window.location.href = 'https://tokenary.io/extension?query=' + query;
                        } else {
                            const response = {subject: "notConfirmed", id: id};
                            window.postMessage(response, "*");
                        }
                    `
                });
            } else {
                browser.tabs.executeScript(tab.id, { code: 'window.location.href = `https://tokenary.io/extension?query=' + query + '`;' });
            }
            sendResponse();
        }
    });
}

// MARK: - helpers

function genId() {
    return new Date().getTime() + Math.floor(Math.random() * 1000);
}

function addListeners() {
    browser.runtime.onMessage.addListener(handleOnMessage);
    browser.browserAction.onClicked.addListener(handleOnClick);
    browser.webNavigation.onBeforeNavigate.addListener(onBeforeExtensionPageNavigation, {url: [{urlMatches : "https://tokenary.io/extension"}]});
}

addListeners();
