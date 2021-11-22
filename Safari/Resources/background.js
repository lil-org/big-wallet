browser.runtime.onMessage.addListener((request, sender, sendResponse) => {
    if (request.subject === "process-inpage-message") {
        browser.runtime.sendNativeMessage("ink.encrypted.macos", request.message, function(response) {
            sendResponse(response)
        });
    }
    return true;
});
