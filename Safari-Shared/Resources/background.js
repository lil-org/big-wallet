var pendingTabIds = {};

function handleUpdated(tabId, changeInfo, tabInfo) {
    const prefix = "https://www.balance.io/blank/?";
    if (tabInfo.url.startsWith(prefix)) {
        const id = tabInfo.url.replace(prefix, "");
        if (id in pendingTabIds) {
            const pendingTabId = pendingTabIds[id];
            browser.tabs.update(pendingTabId, { active: true });
            delete pendingTabIds[id];
        } else {
            const request = { id: parseInt(id), subject: "getResponse" };
            browser.runtime.sendNativeMessage("io.balance", request, function (response) {
                browser.tabs.query({}, function (tabs) {
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
    if (request.subject === "process-inpage-message") {
        didMakeRequest(request.message.id, sender.tab.id);
        browser.runtime.sendNativeMessage("io.balance", request.message, function (response) {
            sendResponse(response);
            didCompleteRequest(request.message.id);
        });
    } else if (request.subject === "activateTab") {
        browser.tabs.update(sender.tab.id, { active: true });
    }
    return true;
});

browser.browserAction.onClicked.addListener(function (tab) {
    const id = new Date().getTime() + Math.floor(Math.random() * 1000);
    const request = { id: id, name: "switchAccount", object: {}, address: "", proxy: true };
    didMakeRequest(request.id, tab.id);
    // TODO: pass current network id
    // TODO: pass favicon
    // TODO: pass host here as well
    browser.runtime.sendNativeMessage("io.balance", request, function (response) {
        browser.tabs.sendMessage(tab.id, response);
        didCompleteRequest(request.id);
    });
    browser.tabs.sendMessage(tab.id, request);
});
