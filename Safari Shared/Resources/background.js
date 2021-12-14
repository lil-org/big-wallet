var pendingTabIds = {};

function handleUpdated(tabId, changeInfo, tabInfo) {
    const prefix = "https://tokenary.io/blank/";
    if (tabInfo.url.startsWith(prefix)) {
        const id = tabInfo.url.replace(prefix, "");
        if (id in pendingTabIds) {
            const pendingTabId = pendingTabIds[id];
            browser.tabs.update(pendingTabId, { active: true });
            delete pendingTabIds[id];
        }
        browser.tabs.remove(tabId);
    }
}

browser.tabs.onUpdated.addListener(handleUpdated);

browser.runtime.onMessage.addListener((request, sender, sendResponse) => {
    if (request.subject === "process-inpage-message") {
        pendingTabIds[request.message.id] = sender.tab.id;
        browser.runtime.sendNativeMessage("mac.tokenary.io", request.message, function(response) {
            sendResponse(response)
        });
    }
    return true;
});

browser.browserAction.onClicked.addListener(function(tab) {
    const id = new Date().getTime() + Math.floor(Math.random() * 1000);
    const request = {id: id, name: "switchAccount", object: {}, address: "", proxy: true};
    pendingTabIds[request.id] = tab.id;
    // TODO: pass current network id
    // TODO: pass favicon
    // TODO: pass host here as well
    browser.runtime.sendNativeMessage("mac.tokenary.io", request, function(response) {
        browser.tabs.sendMessage(tab.id, response);
    });
    browser.tabs.sendMessage(tab.id, request); // In order to open iOS app
});
