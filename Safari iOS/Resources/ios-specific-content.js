// Copyright © 2022 Tokenary. All rights reserved.

function didChangeVisibility() {
    if (document.visibilityState === 'visible' && document.pendingRequestsIds.size != 0) {
        document.pendingRequestsIds.forEach(id => {
            const request = {id: id, subject: "getResponse", host: window.location.host};
            browser.runtime.sendMessage(request).then((response) => {
                sendToInpage(response, id);
            });
        });
    }
}

document.addEventListener('visibilitychange', didChangeVisibility);
