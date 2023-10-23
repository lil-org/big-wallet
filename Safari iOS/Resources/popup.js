// Copyright © 2023 Tokenary. All rights reserved.

const button = document.getElementById('tokenary-button');

button.addEventListener('click', () => {
    const message = browser.extension.getBackgroundPage().sharedData;
    const query = encodeURIComponent(JSON.stringify(message)) + '";';
    browser.tabs.executeScript({
      code: 'window.location.href = "https://tokenary.io/extension?query=' + query
    });
    
    setTimeout( function() {
        window.close();
    }, 200);
});

// TODO: set title depending on a request
button.innerText = "proceed in tokenary";
