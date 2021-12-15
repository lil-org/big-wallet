function didMakeRequest(requestId, tabId) {
    pendingTabIds[requestId] = tabId;
}
