function updateBar() {
    window.ethereum.request({ method: `eth_requestAccounts` }).then((result) => {
        window.postMessage({direction: `from-middleware-script`, subject: `updateBar`, message: JSON.stringify({ address: result[0], balance: `0.00`, })}, `*`);
    });
}

window.ethereum.address !== `` && (updateBar());

window.ethereum.on(`accountsChanged`, () => {
    updateBar();
});
