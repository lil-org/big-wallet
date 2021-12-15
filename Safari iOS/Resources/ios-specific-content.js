function platformSpecificProcessMessage(message) {
    if (message.name != "switchEthereumChain") {
        window.location.href = "tokenary://" + JSON.stringify(message);
    }
}
