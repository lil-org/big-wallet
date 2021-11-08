browser.runtime.onMessage.addListener((request, sender, sendResponse) => {
    console.log("Received request: ", request);

    browser.runtime.sendNativeMessage("ink.encrypted.macos", {message: "Hello from background page"}, function(response) {
        console.log("Received sendNativeMessage response:");
        console.log(response);
    });
    
    if (request.greeting === "hello")
        sendResponse({ farewell: "goodbye" });
});
