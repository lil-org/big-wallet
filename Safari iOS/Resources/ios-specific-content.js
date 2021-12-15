function platformSpecificProcessMessage(message) {
    if (message.name != "switchEthereumChain" && message.name != "addEthereumChain") {
        window.location.href = "tokenary://" + JSON.stringify(message);
    }
}
