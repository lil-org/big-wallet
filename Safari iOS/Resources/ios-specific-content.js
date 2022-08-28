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

function platformSpecificProcessMessage(message) {
    if (message.provider == "ethereum" && (message.name == "switchEthereumChain" || message.name == "addEthereumChain")) {
        return;
    } else {
        // TODO: вот тут, где раньше переходили по диплинку, теперь будем показывать оверлей
        
        // передавать в inpage данные для оверлея:
        // - universal link, который будем открывать
        // - текст для кнопки
        // - данные, достаточные для того, чтобы ответить на запрос ошибкой
        
        // + если он inpage будет отвечать на запрос ошибкой, то мне нужно будет как-то подчищать тот запрос, который ушел extension handler-у
        // или на iOS сделать так, чтобы запрос extension handler-у не уходил до того момента, пока он не нажал на overlay кнопку
        
        const link = "https://tokenary.io/extension?query=" + encodeURIComponent(JSON.stringify(message));
        const response = {overlayLink: link};
        window.postMessage({direction: "from-content-script", response: response, id: message.id}, "*");
        
    }
}
