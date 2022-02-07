window.addEventListener(`message`, function(event) {
    if (event.source == window && event.data && event.data.direction == `from-bar-script`) {
        const response = event.data.response;

        if (response.name === `getAddress`) {
            window.ethereum.request({ method: `eth_requestAccounts` }).then((result) => {
                window.postMessage({direction: `from-middleware-script`, subject: `getAddress`, message: result[0]}, `*`);
            });
        } else if (response.name === `getBalance`) {
            window.postMessage({direction: `from-middleware-script`, subject: `getBalance`, message: `0.00`}, `*`);
        }
    }
});
