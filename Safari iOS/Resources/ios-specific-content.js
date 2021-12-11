function platformSpecificProcessMessage(message) {
    window.location.href = "tokenary://" + JSON.stringify(message);
}
