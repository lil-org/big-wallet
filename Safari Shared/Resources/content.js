const pendingRequestsIds = new Set();

if (window.location.href.startsWith("https://tokenary.io/blank")) {
    browser.runtime.sendMessage({ subject: "wakeUp" });
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
    const storageItem = browser.storage.local.get(window.location.host);
    storageItem.then((storage) => {
        var response = {};
        
        const latest = storage[window.location.host];
        if (typeof latest !== "undefined") {
            response = latest;
        }
        
        response.name = "didLoadLatestConfiguration";
        const id = genId();
        window.postMessage({direction: "from-content-script", response: response, id: id}, "*");
    });
}

function storeConfigurationIfNeeded(request) {
    if (window.location.host.length > 0 && "configurationToStore" in request) {
        const latest = request.configurationToStore;
        browser.storage.local.set( {[window.location.host]: latest});
    }
}

function sendToInpage(response, id) {
    pendingRequestsIds.delete(id);
    window.postMessage({direction: "from-content-script", response: response, id: id}, "*");
    storeConfigurationIfNeeded(response);
}

function sendMessageToNativeApp(message) {
    message.favicon = getFavicon();
    message.host = window.location.host;
    pendingRequestsIds.add(message.id);
    browser.runtime.sendMessage({ subject: "message-to-wallet", message: message }).then((response) => {
        sendToInpage(response, message.id);
    });
    platformSpecificProcessMessage(message); // iOS opens app here
}

function didTapExtensionButton() {
    const id = genId();
    const message = {name: "switchAccount", id: id, provider: "unknown", body: {}};
    // TODO: pass current network id for ethereum. or maybe just pass latestConfiguration here as well
    sendMessageToNativeApp(message);
}

// Receive from background
browser.runtime.onMessage.addListener((request, sender, sendResponse) => {
    if ("didTapExtensionButton" in request) {
        didTapExtensionButton();
    } else {
        if (pendingRequestsIds.has(request.id)) {
            sendToInpage(request, request.id);
            browser.runtime.sendMessage({ subject: "activateTab" });
        }
    }
});

// Receive from inpage
window.addEventListener("message", function(event) {
    if (event.source == window && event.data && event.data.direction == "from-page-script") {
        sendMessageToNativeApp(event.data.message);
    }
});

var getFavicon = function() {
    var nodeList = document.getElementsByTagName("link");
    for (var i = 0; i < nodeList.length; i++) {
        if ((nodeList[i].getAttribute("rel") == "icon") || (nodeList[i].getAttribute("rel") == "shortcut icon")) {
            return nodeList[i].getAttribute("href");
        }
    }
    return "";
}

function genId() {
    return new Date().getTime() + Math.floor(Math.random() * 1000);
}
