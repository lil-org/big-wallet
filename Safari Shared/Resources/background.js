var pendingTabIds = {};

function handleUpdated(tabId, changeInfo, tabInfo) {
    const prefix = "https://tokenary.io/blank/";
    if (tabInfo.url.startsWith(prefix)) {
        const id = tabInfo.url.replace(prefix, "");
        if (id in pendingTabIds) {
            const pendingTabId = pendingTabIds[id];
            browser.tabs.update(pendingTabId, { active: true });
            delete pendingTabIds[id];
        } else {
            const request = {id: parseInt(id), subject: "getResponse"};
            browser.runtime.sendNativeMessage("mac.tokenary.io", request, function(response) {
                browser.tabs.query({}, function(tabs) {
                    tabs.forEach(tab => {
                        browser.tabs.sendMessage(tab.id, response);
                    });
                });
            });
        }
        browser.tabs.remove(tabId);
    }
}

browser.tabs.onUpdated.addListener(handleUpdated);

browser.runtime.onMessage.addListener((request, sender, sendResponse) => {
    if (request.subject === "message-to-wallet") {
        didMakeRequest(request.message.id, sender.tab.id);
        browser.runtime.sendNativeMessage("mac.tokenary.io", request.message, function(response) {
            sendResponse(response);
            didCompleteRequest(request.message.id);
        });
    } else if (request.subject === "activateTab") {
        browser.tabs.update(sender.tab.id, { active: true });
    }
    return true;
});

browser.browserAction.onClicked.addListener(function(tab) {
    const message = {didTapExtensionButton: true};
    browser.tabs.sendMessage(tab.id, message);
    if (tab.url == "" && tab.pendingUrl == "") {
        const id = genId();
        const showAppMessage = {name: "justShowApp", id: id, provider: "unknown", body: {}, host: ""};
        browser.runtime.sendNativeMessage("mac.tokenary.io", showAppMessage);
    }
});

function genId() {
    return new Date().getTime() + Math.floor(Math.random() * 1000);
}
