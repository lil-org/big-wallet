// Copyright © 2022 Tokenary. All rights reserved.

function didChangeVisibility() {
    if (document.visibilityState === 'visible' && pendingRequestsIds.size != 0) {
        pendingRequestsIds.forEach(id => {
            const request = {id: id, subject: "getResponse"};
            browser.runtime.sendMessage(request).then((response) => {
                sendToInpage(response, id);
            });
        });
    }
}

document.addEventListener('visibilitychange', didChangeVisibility);

function platformSpecificProcessMessage(message) {
    if (message.provider == "ethereum" && (message.name == "switchEthereumChain" || message.name == "addEthereumChain")) {
        return;
    } else {
        window.location.href = "tokenary://" + encodeURIComponent(JSON.stringify(message));
    }
}
