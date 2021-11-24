function switchAccount() {
    browser.tabs.query({active: true, currentWindow: true}, function(tabs) {
        browser.tabs.sendMessage(tabs[0].id, {greeting: "hello"});
        window.close();
    });
}

document.getElementById("account").onclick = switchAccount;
