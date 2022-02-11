function platformSpecificProcessMessage(message) {
    if (message.provider == "ethereum" && (message.name == "switchEthereumChain" || message.name == "addEthereumChain")) {
        return;
    } else {
        window.location.href = "tokenary://" + JSON.stringify(message);
    }
}
