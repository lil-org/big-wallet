// Copyright © 2022 Tokenary. All rights reserved.

browser.runtime.onMessage.addListener((request, sender, sendResponse) => {
    if (request.subject === "message-to-wallet") {
        browser.runtime.sendNativeMessage("mac.tokenary.io", request.message, function(response) {
            sendResponse(response);
            browser.tabs.update(sender.tab.id, { active: true });
            didCompleteRequest(request.message.id);
        });
    } else if (request.subject === "getResponse") {
        browser.runtime.sendNativeMessage("mac.tokenary.io", request, function(response) {
            sendResponse(response);
        });
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
