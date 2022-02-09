import logo from './logo.js';

function findOrCreateSessionId () {
    let sessionId = window.sessionStorage.getItem('balanceWalletSessionId');
    if (!sessionId) {
        sessionId = Math.random().toString(36).substring(2, 15);
        window.sessionStorage.setItem('balanceWalletSessionId', sessionId);
    }
    return sessionId;
};

function injectScript() {
    try {
        const container = document.head || document.documentElement;
        const scriptTag = document.createElement(`script`);
        scriptTag.setAttribute(`async`, `false`);
        const request = new XMLHttpRequest();
        request.open(`GET`, browser.extension.getURL(`ios-specific-middleware.js`), false);
        request.send();
        scriptTag.textContent = request.responseText;
        container.insertBefore(scriptTag, container.children[0]);
        container.removeChild(scriptTag);
    } catch (error) {
        console.error(`Middleware injection failed`, error);
    }
}

let barInjected = false;

let data = {
    address: `0x`,
    balance: `0.00`,
    chainId: `1`,
    ticker: `ETH`,
};

let balance;
let address;
let popupLeft;
let popupRight;
let toggle;

function refreshBalanceBar () {
    if (data.address.toString().length === 42) {
        address.innerHTML = `0x<span class="bright">${data.address.slice(2, 5)}</span>&#8230;<span class="bright">${data.address.slice(-5)}</span>`;
        try {
            if (parseFloat(data.balance) < 1) {
                balance.innerHTML = `0.<span class="bright">${data.balance.toString().slice((data.balance.toString().length - 2) * -1)}</span> <span class="currency bright">${data.ticker}</span>`;
            } else if (parseFloat(data.balance) >= 1) {
                balance.innerHTML = `<span class="bright">${data.balance}</span> <span class="currency bright">${data.ticker}</span>`;
            } else {
                balance.innerHTML = `${data.balance} <span class="currency bright">${data.ticker}</span>`;
            }
        } catch (e) {
            balance.innerHTML = ``; // TODO
        }
    } else {
        address.innerHTML = `Not connected`;
        balance.innerHTML = ``;
    }
}

function injectBalanceBar () {

    barInjected = true;

    balance = document.createElement(`div`);
    address = document.createElement(`div`);
    popupLeft = document.createElement(`div`);
    popupRight = document.createElement(`div`);
    toggle = document.createElement(`div`);

    let style = document.createElement(`style`);

    popupLeft.style.display = `none`;
    popupRight.style.display = `none`;

    const toggleBar = () => {
        if (popupLeft.style.display === `none` && popupRight.style.display === `none`) {
            popupLeft.style.display = `flex`;
            popupRight.style.display = `flex`;
            setTimeout(() => {
                popupLeft.style.borderRadius = `23px`;
                popupRight.style.borderRadius = `23px`;
                popupLeft.style.width = `100%`;
                popupRight.style.width = `100%`;
                setTimeout(refreshBalanceBar, 270);
            }, 1);
        } else {
            popupLeft.style.display = `none`;
            popupRight.style.display = `none`;
            address.innerHTML = ``;
            balance.innerHTML = ``;
            setTimeout(() => {
                popupLeft.style.width = `46px`;
                popupRight.style.width = `46px`;
            }, 1);
        }
    };

    popupLeft.className = `bar bar--left`;
    balance.className = `balance`;
    popupLeft.appendChild(balance);
    popupRight.className = `bar bar--right`;
    address.className = `address`;
    popupRight.appendChild(address);

    toggle.role = `button`;
    toggle.className = `toggle`;
    toggle.addEventListener(`click`, toggleBar);
    toggle.innerHTML = logo;

    style.type = `text/css`;
    // ! This is not yet optimized to reduce style conflicts:
    style.innerHTML = `
        .bar {
            -moz-transition: width 1s ease-in-out;
            -o-transition: width 1s ease-in-out;
            -webkit-transition: width 1s ease-in-out;
            align-items: center;
            background-color: #000;
            border-radius: 23px 0 0 23px;
            bottom: 16px;
            display: none;
            height: 46px;
            max-width: calc(50vw - 16px);
            opacity: .9;
            position: fixed;
            transition: opacity .11s ease, width .27s ease-in-out;
            width: 46px;
            will-change: opacity, width;
            z-index: 99999999999;
        }
        .bar--left {
            align-items: center;
            border-radius: 23px 0 0 23px;
            column-gap: 8px;
            display: none;
            justify-content: flex-start;
            padding-left: 16px;
            right: calc(50vw - 16px);
            z-index: 99999999998;
        }
        .bar--right {
            align-items: center;
            border-radius: 0 23px 23px 0;
            column-gap: 8px;
            display: none;
            justify-content: flex-end;
            left: calc(50vw - 16px);
            padding-right: 16px;
            z-index: 99999999998;
        }
        .network {
            height: 40px;
            width: 40px;
        }
        .text {
            align-items: center;
            color: #fff;
            display: flex;
            height: 46px;
            justify-content: space-between;
            max-width: calc(100vw - 100px);
            width: 100%;
        }
        .balance, .address {
            color: #b0afb0;
            font-size: 16px;
        }
        .bright {
            color: #fff;
        }
        .currency {
            font-size: 14px;
        }
        .toggle {
            -webkit-tap-highlight-color: rgba(0, 0, 0, 0);
            bottom: 16px;
            height: 46px;
            position: fixed;
            right: calc(50vw - 23px);
            transition: transform .11s ease-in-out;
            width: 46px;
            z-index: 99999999999999;
        }
    `;

    document.body.appendChild(style);
    document.body.appendChild(popupLeft);
    document.body.appendChild(popupRight);
    document.body.appendChild(toggle);

}

window.addEventListener(`message`, function (event) {
    if (event.source == window && event.data && event.data.subject && event.data.direction == `from-middleware-script`) {
        if (event.data.subject === `updateBar`) {
            const json = JSON.parse(event.data.message);
            data.address = json.address;
            try {
                data.balance = (Number.parseInt(json.balance, 16) / (10 ** 18)).toFixed(2);
            } catch (e) {
                data.balance = json.balance;
            }
            if (data.address !== ``) {
                if (!barInjected) {
                    injectBalanceBar();
                } else if (popupLeft.style.display === `flex` && popupRight.style.display === `flex`) {
                    refreshBalanceBar();
                }
            }
        }
    }
});

setTimeout(injectScript, 100);
