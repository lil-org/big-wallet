function startBar() {
    window.ethereum.address !== `` && (updateBar());

    window.ethereum.on(`accountsChanged`, () => {
        updateBar();
    });
}

function updateBar() {
    window.ethereum.request({ method: `eth_requestAccounts` }).then((result) => {
        const xhr = new XMLHttpRequest();
        xhr.onload = () => {
            const res = xhr.response;
            const json = JSON.parse(res);
            window.postMessage({direction: `from-middleware-script`, subject: `updateBar`, message: JSON.stringify({ address: result[0], balance: json.result, })}, `*`);
        }
        xhr.onerror = () => {
            console.log(`Request failed.`);
        };
        xhr.open(`POST`, window.ethereum.rpc.rpcUrl, true);
        xhr.setRequestHeader(`Content-Type`, `application/json`);
        xhr.send(JSON.stringify({"jsonrpc":"2.0","method":"eth_getBalance","params": [result[0], "latest"],"id":1}));
    });
}

if (typeof window.ethereum !== `undefined`) {
    startBar();
} else {
    const interval = setInterval(() => {
        if (typeof window.ethereum !== `undefined`) {
            clearInterval(interval);
            startBar();
        }
    }, 1000);
}
