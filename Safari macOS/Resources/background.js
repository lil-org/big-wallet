browser.runtime.onMessage.addListener((request, sender, sendResponse) => {
    if (request.subject === "closeTab") {
        browser.tabs.remove(sender.tab.id);
    } else if (request.subject === "process-inpage-message") {
        browser.runtime.sendNativeMessage("mac.tokenary.io", request.message, function(response) {
            sendResponse(response)
        });
    }
    return true;
});

browser.browserAction.onClicked.addListener(function(tab) {
    const id = new Date().getTime() + Math.floor(Math.random() * 1000);
    const request = {id: id, name: "switchAccount", object: {}, address: ""};
    // TODO: pass current network id
    // TODO: pass favicon
    // TODO: pass host here as well
    browser.runtime.sendNativeMessage("mac.tokenary.io", request, function(response) {
        browser.tabs.sendMessage(tab.id, response);
    });
});
