function didMakeRequest(requestId, tabId) {
    pendingTabIds[requestId] = tabId;
}

function didCompleteRequest(id) {
    const request = {id: id, subject: "didCompleteRequest"};
    browser.runtime.sendNativeMessage("mac.tokenary.io", request);
}
