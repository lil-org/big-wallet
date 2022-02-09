function didMakeRequest(requestId, tabId) {
    pendingTabIds[requestId] = tabId;
}

function didCompleteRequest(id) {
    const request = { id: id, subject: "didCompleteRequest" };
    browser.runtime.sendNativeMessage("io.balance", request);
}

console.log('test');
