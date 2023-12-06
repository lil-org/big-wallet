// Copyright © 2022 Tokenary. All rights reserved.

if (!("pendingRequestsIds" in document)) {
    document.pendingRequestsIds = new Set();
}

function injectScript() {
    const container = document.head || document.documentElement;
    const scriptTag = document.createElement('script');
    scriptTag.setAttribute('async', 'false');

    fetch(browser.runtime.getURL('inpage.js'))
        .then(response => response.text())
        .then(data => {
            scriptTag.textContent = data;
            container.insertBefore(scriptTag, container.children[0]);
            container.removeChild(scriptTag);
        })
        .catch(error => {
            console.error('tokenary: failed to inject', error);
        });
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

if (shouldInjectProvider()) {
    if (document.readyState != "loading") {
        window.location.reload();
    } else {
        injectScript();
        getLatestConfiguration();
    }
}

function getLatestConfiguration() {
    const request = {subject: "getLatestConfiguration", host: window.location.host};
    browser.runtime.sendMessage(request).then((response) => {
        const id = genId();
        window.postMessage({direction: "from-content-script", response: response, id: id}, "*");
    });
}

function sendToInpage(response, id) {
    if (document.pendingRequestsIds.has(id)) {
        document.pendingRequestsIds.delete(id);
        window.postMessage({direction: "from-content-script", response: response, id: id}, "*");
    }
}

function sendMessageToNativeApp(message) {
    message.favicon = getFavicon();
    message.host = window.location.host;
    document.pendingRequestsIds.add(message.id);
    browser.runtime.sendMessage({ subject: "message-to-wallet", message: message, host: window.location.host }).then((response) => {
        sendToInpage(response, message.id);
    });
}

// Receive from service-worker
browser.runtime.onMessage.addListener((request, sender, sendResponse) => {
    if ("didTapExtensionButton" in request) {
        sendResponse(window.location.host);
    } else if ("name" in request && request.name == "switchAccount") {
        sendMessageToNativeApp(request);
    }
});

// Receive from inpage
window.addEventListener("message", function(event) {
    if (event.source == window && event.data) {
        if (event.data.direction == "from-page-script") {
            sendMessageToNativeApp(event.data.message);
        } else if (event.data.subject == "disconnect") {
            const disconnectRequest = event.data;
            disconnectRequest.host = window.location.host;
            browser.runtime.sendMessage(disconnectRequest);
        }
    }
});

var getFavicon = function() {
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

function genId() {
    return new Date().getTime() + Math.floor(Math.random() * 1000);
}
