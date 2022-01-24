function platformSpecificProcessMessage(message) {
    if (message.name != "switchEthereumChain" && message.name != "addEthereumChain") {
        window.location.href = "balance://" + JSON.stringify(message);
    }
}
