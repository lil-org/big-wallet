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
        const host = request.host;
        const hostGeneration =
            retainAlchemyPrewarmHostGenerationRead(host);
        const queuedWrite = latestConfigurationWriteQueues.get(host);
        let canPrewarm = true;
        const waitForWrite = queuedWrite ?
            queuedWrite.catch(() => {
                canPrewarm = false;
            }) :
            Promise.resolve();
        waitForWrite.then(() => {
            return getLatestConfiguration(host);
        }).then(currentConfiguration => {
            if (canPrewarm &&
                currentAlchemyPrewarmHostGeneration(host) ===
                hostGeneration) {
                prewarmAlchemyIfConfigured(currentConfiguration, host);
            }
            sendResponse(currentConfiguration);
        }).catch(() => {
            sendResponse();
        }).then(() => {
            releaseAlchemyPrewarmHostGenerationRead(host);
        }, () => {
            releaseAlchemyPrewarmHostGenerationRead(host);
        });
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
let alchemyPrewarmRequest;
let activeAlchemyPrewarmConfiguration;
let pendingAlchemyPrewarmConfiguration;
let pendingAlchemyPrewarmHosts = new Map();
let nextAlchemyPrewarmGeneration = 0;
const alchemyPrewarmHostStates = new Map();

function storeLatestConfiguration(host, configuration) {
    const replacesEthereumConfiguration = Array.isArray(configuration) ||
        (configuration &&
            configuration.provider === "ethereum");
    if (Array.isArray(configuration)) {
        queueLatestConfigurationWrite(host, () => {
            return browser.storage.local.set({ [host]: latestConfigurationsArray(configuration) });
        });
    } else if (configuration && "provider" in configuration) {
        queueLatestConfigurationUpdate(host, latestArray => latestConfigurationsReplacing(latestArray, configuration));
    }
    prewarmAlchemyIfConfigured(
        configuration,
        host,
        replacesEthereumConfiguration
    );
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
    const ethereumRemovalGeneration = provider === "ethereum" ?
        advanceAlchemyPrewarmHostGeneration(host) :
        undefined;
    const removal = queueLatestConfigurationUpdate(host, (latestArray) => {
        return latestArray.filter(configuration => configuration.provider != provider);
    });
    if (typeof ethereumRemovalGeneration === "undefined") {
        return removal;
    }
    return removal.then(() => {
        removePendingAlchemyPrewarmHost(
            host,
            ethereumRemovalGeneration
        );
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
            pruneAlchemyPrewarmHostState(host);
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

function prewarmAlchemyIfConfigured(
    configuration,
    host,
    replacesEthereumConfiguration
) {
    let hostGeneration = currentAlchemyPrewarmHostGeneration(host);
    if (replacesEthereumConfiguration) {
        hostGeneration = advanceAlchemyPrewarmHostGeneration(host);
        removePendingAlchemyPrewarmHost(host);
    }
    const configurations = latestConfigurationsArray(configuration);
    const current = configurations.find(current =>
        current &&
        current.provider === "ethereum" &&
        typeof current.chainId === "string"
    );
    if (!current) {
        return;
    }
    if (alchemyPrewarmRequest) {
        if (sameAlchemyPrewarmConfiguration(
                current,
                activeAlchemyPrewarmConfiguration
            )) {
            return;
        }
        if (sameAlchemyPrewarmConfiguration(
                current,
                pendingAlchemyPrewarmConfiguration
            )) {
            setPendingAlchemyPrewarmHost(host, hostGeneration);
            return;
        }
        pendingAlchemyPrewarmConfiguration = current;
        replacePendingAlchemyPrewarmHosts(
            new Map([[host, hostGeneration]])
        );
        return;
    }

    const request = {
        id: genId(),
        subject: "prewarmAlchemy",
        provider: current.provider,
        chainId: current.chainId
    };

    let pendingRequest;
    try {
        pendingRequest = browser.runtime.sendNativeMessage(
            "org.lil.wallet",
            request
        );
    } catch (error) {
        return;
    }
    alchemyPrewarmRequest = pendingRequest;
    activeAlchemyPrewarmConfiguration = current;
    const clearPendingRequest = () => {
        if (alchemyPrewarmRequest === pendingRequest) {
            alchemyPrewarmRequest = undefined;
            activeAlchemyPrewarmConfiguration = undefined;
            const pendingConfiguration = pendingAlchemyPrewarmConfiguration;
            const pendingHosts = pendingAlchemyPrewarmHosts;
            pendingAlchemyPrewarmConfiguration = undefined;
            pendingAlchemyPrewarmHosts = new Map();
            if (pendingConfiguration) {
                for (const [pendingHost, pendingGeneration] of
                    pendingHosts) {
                    if (currentAlchemyPrewarmHostGeneration(pendingHost) !==
                        pendingGeneration) {
                        pruneAlchemyPrewarmHostState(pendingHost);
                        continue;
                    }
                    prewarmAlchemyIfConfigured(
                        [pendingConfiguration],
                        pendingHost
                    );
                    pruneAlchemyPrewarmHostState(pendingHost);
                }
            } else {
                for (const pendingHost of pendingHosts.keys()) {
                    pruneAlchemyPrewarmHostState(pendingHost);
                }
            }
        }
    };
    pendingRequest.then(clearPendingRequest, clearPendingRequest);
}

function currentAlchemyPrewarmHostGeneration(host) {
    const state = alchemyPrewarmHostStates.get(host);
    return state ? state.generation : 0;
}

function advanceAlchemyPrewarmHostGeneration(host) {
    nextAlchemyPrewarmGeneration += 1;
    const state = alchemyPrewarmHostState(host);
    state.generation = nextAlchemyPrewarmGeneration;
    return state.generation;
}

function retainAlchemyPrewarmHostGenerationRead(host) {
    const state = alchemyPrewarmHostState(host);
    state.inFlightReadCount += 1;
    return state.generation;
}

function releaseAlchemyPrewarmHostGenerationRead(host) {
    const state = alchemyPrewarmHostStates.get(host);
    if (!state) {
        return;
    }
    if (state.inFlightReadCount > 0) {
        state.inFlightReadCount -= 1;
    }
    pruneAlchemyPrewarmHostState(host);
}

function alchemyPrewarmHostState(host) {
    let state = alchemyPrewarmHostStates.get(host);
    if (!state) {
        state = {
            generation: 0,
            inFlightReadCount: 0,
        };
        alchemyPrewarmHostStates.set(host, state);
    }
    return state;
}

function pruneAlchemyPrewarmHostState(host) {
    const state = alchemyPrewarmHostStates.get(host);
    if (!state ||
        state.inFlightReadCount !== 0 ||
        latestConfigurationWriteQueues.has(host) ||
        pendingAlchemyPrewarmHosts.has(host)) {
        return;
    }
    alchemyPrewarmHostStates.delete(host);
}

function setPendingAlchemyPrewarmHost(host, generation) {
    const state = alchemyPrewarmHostState(host);
    state.generation = generation;
    pendingAlchemyPrewarmHosts.set(host, generation);
}

function replacePendingAlchemyPrewarmHosts(nextPendingHosts) {
    const previousPendingHosts = pendingAlchemyPrewarmHosts;
    pendingAlchemyPrewarmHosts = new Map();
    for (const [host, generation] of nextPendingHosts) {
        setPendingAlchemyPrewarmHost(host, generation);
    }
    for (const host of previousPendingHosts.keys()) {
        pruneAlchemyPrewarmHostState(host);
    }
}

function removePendingAlchemyPrewarmHost(host, throughGeneration) {
    const pendingGeneration = pendingAlchemyPrewarmHosts.get(host);
    if (typeof throughGeneration !== "undefined" &&
        typeof pendingGeneration !== "undefined" &&
        pendingGeneration > throughGeneration) {
        return;
    }
    pendingAlchemyPrewarmHosts.delete(host);
    if (pendingAlchemyPrewarmHosts.size === 0) {
        pendingAlchemyPrewarmConfiguration = undefined;
    }
    pruneAlchemyPrewarmHostState(host);
}

function sameAlchemyPrewarmConfiguration(lhs, rhs) {
    return lhs &&
        rhs &&
        lhs.provider === rhs.provider &&
        lhs.chainId === rhs.chainId;
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
