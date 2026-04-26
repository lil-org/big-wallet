// ∅ 2026 lil org

function handleOnMessage(request, sender, sendResponse) {
    if (request.subject === "rpc") {
        browser.runtime.sendNativeMessage("org.lil.wallet", request).then(response => {
            if (typeof response !== "undefined") {
                sendResponse(response);
            } else { sendResponse(); }
        }).catch(() => { sendResponse(); });
    } else if (request.subject === "message-to-wallet") {
        browser.runtime.sendNativeMessage("org.lil.wallet", request.message).then(response => {
            if (typeof response !== "undefined") {
                sendResponse(response);
                updateStoredConfigurationIfNeeded(request.host, response);
            } else {
                if (!request.navigate) {
                    sendResponse();
                }
            }
        }).catch(() => {
            if (!request.navigate) {
                sendResponse();
            }
        });
        
        if (request.navigate) {
            mobileRedirectFor(request, sendResponse);
        }
    } else if (request.subject === "getResponse") {
        browser.runtime.sendNativeMessage("org.lil.wallet", request).then(response => {
            if (typeof response !== "undefined") {
                sendResponse(response);
                updateStoredConfigurationIfNeeded(request.host, response);
            } else { sendResponse(); }
        }).catch(() => { sendResponse(); });
    } else if (request.subject === "cancelRequest") {
        browser.runtime.sendNativeMessage("org.lil.wallet", request).then(() => {}).catch(() => {});
        sendResponse();
    } else if (request.subject === "getLatestConfiguration") {
        getLatestConfiguration(request.host).then(currentConfiguration => {
            sendResponse(currentConfiguration);
        }).catch(() => { sendResponse(); });
    } else if (request.subject === "disconnect") {
        const provider = request.provider;
        const host = request.host;
        removeLatestConfiguration(host, provider).then(() => {
            sendResponse();
        }).catch(() => { sendResponse(); });
    } else {
        sendResponse();
    }
    return true;
}

const latestConfigurationWriteQueues = new Map();

function storeLatestConfiguration(host, configuration) {
    if (Array.isArray(configuration)) {
        queueLatestConfigurationWrite(host, () => {
            return browser.storage.local.set({ [host]: latestConfigurationsArray(configuration) });
        });
    } else if (configuration && "provider" in configuration) {
        queueLatestConfigurationUpdate(host, latestArray => latestConfigurationsReplacing(latestArray, configuration));
    }
}

function latestConfigurationsReplacing(latestArray, configuration) {
    const updatedArray = latestArray.slice();
    for (var i = 0; i < updatedArray.length; i++) {
        if (updatedArray[i].provider == configuration.provider) {
            updatedArray[i] = configuration;
            return updatedArray;
        }
    }
    updatedArray.push(configuration);
    return updatedArray;
}

function removeLatestConfiguration(host, provider) {
    return queueLatestConfigurationUpdate(host, (latestArray) => {
        return latestArray.filter(configuration => configuration.provider != provider);
    });
}

function removeLatestSolanaConfigurationIfMatching(host, publicKey) {
    return queueLatestConfigurationUpdate(host, (latestArray) => {
        return latestArray.filter(configuration => {
            return configuration.provider != "solana" || configuration.publicKey !== publicKey;
        });
    });
}

function queueLatestConfigurationUpdate(host, update) {
    return queueLatestConfigurationWrite(host, async () => {
        const latest = await getLatestConfiguration(host);
        const currentArray = latestConfigurationsArray(latest);
        const updatedArray = latestConfigurationsArray(update(currentArray));
        await browser.storage.local.set({ [host]: updatedArray });
    });
}

function queueLatestConfigurationWrite(host, write) {
    const previousWrite = latestConfigurationWriteQueues.get(host) || Promise.resolve();
    const queuedWrite = previousWrite
        .catch(() => {})
        .then(write);

    latestConfigurationWriteQueues.set(host, queuedWrite);
    const clearQueueIfLatest = () => {
        if (latestConfigurationWriteQueues.get(host) === queuedWrite) {
            latestConfigurationWriteQueues.delete(host);
        }
    };
    queuedWrite.then(clearQueueIfLatest, clearQueueIfLatest);

    return queuedWrite;
}

function latestConfigurationsArray(latest) {
    if (Array.isArray(latest)) {
        return latest.slice();
    }
    if (latest && Array.isArray(latest.latestConfigurations)) {
        return latest.latestConfigurations.slice();
    }
    if (typeof latest !== "undefined" && latest && "provider" in latest) {
        return [latest];
    }
    return [];
}

function getLatestConfiguration(host) {
    return new Promise((resolve) => {
        browser.storage.local.get(host).then(result => {
            resolve({ latestConfigurations: latestConfigurationsArray(result[host]) });
        }).catch(() => {
            resolve({ latestConfigurations: [] });
        });
    });
}

function updateStoredConfigurationIfNeeded(host, response) {
    if (!host || !response || typeof response !== "object") {
        return;
    }

    if (response.errorCode === 4100 &&
        response.provider === "solana" &&
        typeof response.errorPublicKey === "string") {
        removeLatestSolanaConfigurationIfMatching(host, response.errorPublicKey);
    } else if ("configurationToStore" in response) {
        storeLatestConfiguration(host, response.configurationToStore);
    }
}

function onBeforeExtensionPageNavigation(details) {
    if (details.url.includes("lil.org/extension?query=")) {
        const queryStringIndex = details.url.indexOf("?query=") + 7;
        const encodedQuery = details.url.substring(queryStringIndex);
        browser.tabs.update(details.tabId, { url: "bigwallet://safari?request=" + encodedQuery });
    }
}

function justShowApp() {
    const id = genId();
    const showAppMessage = {name: "justShowApp", id: id, provider: "unknown", body: {}, host: ""};
    browser.runtime.sendNativeMessage("org.lil.wallet", showAppMessage).then(() => {}).catch(() => {});
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
    browser.tabs.getCurrent((tab) => {
        if (tab) {
            if (request.confirm) {
                const confirmationText = request.message.host + " | connect wallet";
                browser.tabs.executeScript(tab.id, {
                    code: `
                        var query = '` + query + `';
                        var confirmationText = '` + confirmationText + `';
                        var id = ` + request.message.id + `;
                        var provider = '` + request.message.provider + `';
                        if (confirm(confirmationText)) {
                            window.location.href = 'https://lil.org/extension?query=' + query;
                        } else {
                            const response = {subject: "notConfirmed", id: id, provider: provider};
                            window.postMessage(response, "*");
                        }
                    `
                });
            } else {
                browser.tabs.executeScript(tab.id, { code: 'window.location.href = `https://lil.org/extension?query=' + query + '`;' });
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
    browser.webNavigation.onBeforeNavigate.addListener(onBeforeExtensionPageNavigation, {url: [{urlMatches : "https://(www\.)?lil\.org/extension"}]});
}

addListeners();
