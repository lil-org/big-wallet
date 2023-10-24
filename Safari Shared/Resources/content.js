// Copyright © 2022 Tokenary. All rights reserved.

if (!("pendingRequestsIds" in document)) {
    document.pendingRequestsIds = new Set();
}

function injectScript() {
    try {
        const container = document.head || document.documentElement;
        const scriptTag = document.createElement('script');
        scriptTag.setAttribute('async', 'false');
        var request = new XMLHttpRequest();
        request.open('GET', browser.extension.getURL('inpage.js'), false);
        request.send();
        scriptTag.textContent = request.responseText;
        container.insertBefore(scriptTag, container.children[0]);
        container.removeChild(scriptTag);
    } catch (error) {
        console.error('Tokenary: Provider injection failed.', error);
    }
}

function shouldInjectProvider() {
    return (doctypeCheck() && suffixCheck() && documentElementCheck() && !blockedDomainCheck());
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

function blockedDomainCheck() {
    const blockedDomains = [
        'uscourts.gov',
        'dropbox.com',
        'webbyawards.com',
        'cdn.shopify.com/s/javascripts/tricorder/xtld-read-only-frame.html',
        'adyen.com',
        'gravityforms.com',
        'harbourair.com',
        'ani.gamer.com.tw',
        'blueskybooking.com',
        'sharefile.com',
    ];
    const currentUrl = window.location.href;
    let currentRegex;
    for (let i = 0; i < blockedDomains.length; i++) {
        const blockedDomain = blockedDomains[i].replace('.', '\\.');
        currentRegex = new RegExp(`(?:https?:\\/\\/)(?:(?!${blockedDomain}).)*$`, 'u');
        if (!currentRegex.test(currentUrl)) {
            return true;
        }
    }
    return false;
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

// Receive from background
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
