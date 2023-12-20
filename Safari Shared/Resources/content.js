// Copyright © 2023 Tokenary. All rights reserved.

if (!("pendingRequestsIds" in document)) {
    document.pendingRequestsIds = new Set();
    document.loadedAt = Date.now();
    document.alwaysConfirm = false;
    document.navigationBlocked = false;
    document.requestsQueue = [];
    setup();
}

function setup() {
    if (shouldInjectProvider()) {
        if (document.readyState != "loading") {
            window.location.reload();
        } else {
            injectScript();
            getLatestConfiguration();
        }
    }
    
    // Receive from service-worker
    browser.runtime.onMessage.addListener((request, sender, sendResponse) => {
        if ("didTapExtensionButton" in request) {
            sendResponse({ host: window.location.host, favicon: getFavicon() });
        } else if ("name" in request && request.name == "switchAccount") {
            sendMessageToNativeApp(request, false);
            sendResponse();
        } else {
            sendResponse();
        }
        return true;
    });

    // Receive from inpage
    window.addEventListener("message", event => {
        if (event.source == window && event.data) {
            if (event.data.direction == "from-page-script") {
                sendMessageToNativeApp(event.data.message, false);
            } else if (event.data.subject == "disconnect") {
                const disconnectRequest = event.data;
                disconnectRequest.host = window.location.host;
                disconnectRequest.navigate = false;
                disconnectRequest.confirm = false;
                browser.runtime.sendMessage(disconnectRequest).then(() => {}).catch(() => {});
            } else if (event.data.subject == "notConfirmed") {
                document.navigationBlocked = false;
                document.alwaysConfirm = true;
                cancelRequest(event.data.id, event.data.provider);
                cleanupRequestsQueue();
            }
        }
    });
    
    document.addEventListener('visibilitychange', didChangeVisibility);
    if (!isMobile) {
        window.addEventListener('focus', didChangeVisibility);
    }
}

function injectScript() {
    try {
        const container = document.head || document.documentElement;
        const scriptTag = document.createElement('script');
        scriptTag.setAttribute('async', 'false');
        var request = new XMLHttpRequest();
        request.open('GET', browser.runtime.getURL('inpage.js'), false);
        request.send();
        scriptTag.textContent = request.responseText;
        container.insertBefore(scriptTag, container.children[0]);
        container.removeChild(scriptTag);
    } catch (error) {
        console.error('tokenary: failed to inject', error);
    }
}

function cancelRequest(id, provider) {
    const cancelMessage = {
        id: id,
        provider: provider,
        error: "canceled",
        subject: "cancelRequest",
    };
    sendToInpage(cancelMessage, id);
    browser.runtime.sendMessage(cancelMessage).then(() => {}).catch(() => {});
}

function shouldInjectProvider() {
    return (doctypeCheck() && suffixCheck() && documentElementCheck());
}

function doctypeCheck() {
    const { doctype } = window.document;
    if (doctype) {
        return doctype.name === 'html';
    }
    return true;
}

function suffixCheck() {
    const prohibitedTypes = [/\.xml$/u, /\.pdf$/u];
    const currentUrl = window.location.pathname;
    for (let i = 0; i < prohibitedTypes.length; i++) {
        if (prohibitedTypes[i].test(currentUrl)) {
            return false;
        }
    }
    return true;
}

function documentElementCheck() {
    const documentElement = document.documentElement.nodeName;
    if (documentElement) {
        return documentElement.toLowerCase() === 'html';
    }
    return true;
}

function getLatestConfiguration() {
    const request = {subject: "getLatestConfiguration", host: window.location.host, navigate: false, confirm: false};
    browser.runtime.sendMessage(request).then((response) => {
        if (typeof response === "undefined") { return; }
        const id = genId();
        window.postMessage({direction: "from-content-script", response: response, id: id}, "*");
    }).catch(() => {});
}

function sendToInpage(response, id) {
    if (typeof response === "undefined") { return; }
    if (document.pendingRequestsIds.has(id)) {
        document.pendingRequestsIds.delete(id);
        window.postMessage({direction: "from-content-script", response: response, id: id}, "*");
    }
}

function sendMessageToNativeApp(message, fromQueue) {
    const requiresNavigation = requiresNavigationFor(message.name);
    if (isMobile && requiresNavigation && document.navigationBlocked) {
        addRequestToQueue(message);
    } else {
        if (isMobile && requiresNavigation) {
            document.navigationBlocked = true;
            if (!fromQueue) {
                cleanupRequestsQueue();
            }
        }
        message.favicon = getFavicon();
        message.host = window.location.host;
        document.pendingRequestsIds.add(message.id);
        browser.runtime.sendMessage({ subject: "message-to-wallet",
            message: message,
            host: window.location.host,
            navigate: requiresNavigation,
            confirm: requiresConfirmation(message.name)}).then((response) => {
            if (typeof response === "undefined") { return; }
            sendToInpage(response, message.id);
        }).catch(() => {});
    }
}

function addRequestToQueue(request) {
    if (isMobile) {
        document.requestsQueue.push(request);
    }
}

function processRequestsQueueIfNeeded() {
    if (isMobile && document.requestsQueue.length > 0) {
        setTimeout(processNextItemInQueue, 999);
    }
}

function processNextItemInQueue() {
    if (document.requestsQueue.length > 0) {
        const next = document.requestsQueue.shift();
        sendMessageToNativeApp(next, true);
    }
}

function cleanupRequestsQueue() {
    if (isMobile && document.requestsQueue.length > 0) {
        for (var i = 0; i < document.requestsQueue.length; i++) {
            const request = document.requestsQueue[i];
            cancelRequest(request.id, request.provider);
        }
        document.requestsQueue = [];
    }
}

function getFavicon() {
    if (document.favicon) {
        return document.favicon;
    }
    
    var nodeList = document.getElementsByTagName("link");
    for (var i = 0; i < nodeList.length; i++) {
        if ((nodeList[i].getAttribute("rel") == "apple-touch-icon") || (nodeList[i].getAttribute("rel") == "icon") || (nodeList[i].getAttribute("rel") == "shortcut icon")) {
            const favicon = nodeList[i].getAttribute("href");
            if (!favicon.endsWith("svg")) {
                document.favicon = favicon;
                return favicon;
            }
        }
    }
    return "";
}

function requiresConfirmation(name) {
    if (isMobile) {
        const timeDelta = Date.now() - document.loadedAt;
        return (timeDelta < 999 || document.alwaysConfirm) && (name == "requestAccounts");
    } else {
        return false;
    }
}

function requiresNavigationFor(name) {
    if (isMobile && name != "switchEthereumChain" && name != "addEthereumChain") {
        return true;
    } else {
        return false;
    }
}

function genId() {
    return new Date().getTime() + Math.floor(Math.random() * 1000);
}

function didChangeVisibility() {
    const isVisible = document.visibilityState === 'visible';
    if (isMobile && document.navigationBlocked && isVisible) {
        document.navigationBlocked = false;
        processRequestsQueueIfNeeded();
    }
    if (document.pendingRequestsIds.size != 0 && isVisible) {
        document.pendingRequestsIds.forEach(id => {
            const request = {id: id, subject: "getResponse", host: window.location.host, navigate: false, confirm: false};
            browser.runtime.sendMessage(request).then(response => {
                if (typeof response !== "undefined") {
                    sendToInpage(response, id);
                }
            }).catch(() => {});
        });
    }
}
