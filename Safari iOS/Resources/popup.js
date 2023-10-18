// Copyright © 2023 Tokenary. All rights reserved.

document.getElementById('tokenary-button').addEventListener('click', () => {
    browser.tabs.executeScript({
      code: 'window.location.href = "https://tokenary.io/extension";'
    });
    
    // TODO: how to get a request body here?
    
    setTimeout( function() {
        window.close();
    }, 200);
});
