browser.runtime.onMessage.addListener((request, sender, sendResponse) => {
    if (request.subject === "process-inpage-message") {
        browser.runtime.sendNativeMessage("ink.encrypted.macos", request.message, function(response) {
            sendResponse(response)
        });
    }
    return true;
});

browser.browserAction.onClicked.addListener(function(tab) {
    const id = new Date().getTime() + Math.floor(Math.random() * 1000);
    const request = {id: id, name: "switchAccount", object: {}, address: ""};
    browser.runtime.sendNativeMessage("ink.encrypted.macos", request, function(response) {
        browser.tabs.sendMessage(tab.id, response);
    });
});
