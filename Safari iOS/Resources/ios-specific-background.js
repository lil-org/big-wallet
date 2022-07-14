// Copyright © 2022 Tokenary. All rights reserved.

function didCompleteRequest(id, tabId) {
    browser.tabs.update(tabId, { active: true });
    const request = {id: id, subject: "didCompleteRequest"};
    browser.runtime.sendNativeMessage("mac.tokenary.io", request);
}
