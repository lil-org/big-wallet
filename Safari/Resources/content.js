if (document.readyState === "complete") {
    window.location.reload();
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
        console.error('Encrypted Ink: Provider injection failed.', error);
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
    injectScript();
    getLatestAccount();
}

function getLatestAccount() {
    const storageItem = browser.storage.local.get(window.location.host);
    storageItem.then((storage) => {
        const latest = storage[window.location.host];
        if (typeof latest !== "undefined" && latest.results.length > 0 && latest.rpcURL.length > 0) {
            const response = {results: latest.results, chainId: latest.chainId, name: "switchAccount", rpcURL: latest.rpcURL, repeatOnSubscription: true};
            const id = new Date().getTime() + Math.floor(Math.random() * 1000);
            window.postMessage({direction: "from-content-script", response: response, id: id}, "*");
        }
    });
}

function storeAccountIfNeeded(request) {
    if (window.location.host.length > 0 && (request.name == "requestAccounts" || request.name == "switchAccount")) {
        const latest = {results: request.results, chainId: request.chainId, rpcURL: request.rpcURL};
        browser.storage.local.set( {[window.location.host]: latest});
    }
}

function processInpageMessage(message) {
    browser.runtime.sendMessage({ subject: "process-inpage-message", message: message }).then((response) => {
        window.postMessage({direction: "from-content-script", response: response, id: message.id}, "*");
        storeAccountIfNeeded(response);
    });
}

// Receive from background
browser.runtime.onMessage.addListener((request, sender, sendResponse) => {
    const id = new Date().getTime() + Math.floor(Math.random() * 1000);
    window.postMessage({direction: "from-content-script", response: request, id: id}, "*");
    storeAccountIfNeeded(request);
});

// Receive from inpage
window.addEventListener("message", function(event) {
    if (event.source == window && event.data && event.data.direction == "from-page-script") {
        processInpageMessage(event.data.message);
    }
});
