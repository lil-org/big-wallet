function switchAccount() {
    browser.tabs.query({active: true, currentWindow: true}, function(tabs) {
        const id = new Date().getTime() + Math.floor(Math.random() * 1000);
        const request = {id: id, name: "switchAccount", object: {}, address: ""};
        browser.tabs.sendMessage(tabs[0].id, request);
    });
}

document.getElementById("account").onclick = switchAccount;
