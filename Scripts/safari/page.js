"use strict";

(async () => {
    document.getElementById("fixture-origin").textContent = `Fixture origin: ${location.origin}`;
    const config = await (await fetch("/page-config")).json();
    document.getElementById("fixture-document").textContent = `Fixture document: ${config.documentId}`;
    const resultNode = document.getElementById("result");
    const actions = ["ethereum-connect", "ethereum-sign", "ethereum-send", "ethereum-revoke", "ethereum-chain", "ethereum-mainnet", "ethereum-permissions",
        "ethereum-add-custom", "ethereum-switch-custom", "ethereum-send-custom", "ethereum-send-estimated",
        "solana-connect", "solana-sign", "solana-send", "solana-transaction-sign", "solana-batch-sign", "rpc-burst", "rpc-error", "provider-state", "malformed-requests"];
    const serializable = value => JSON.parse(JSON.stringify(value, (_, item) =>
        ArrayBuffer.isView(item) ? [...new Uint8Array(item.buffer, item.byteOffset, item.byteLength)] : item));
    const report = async value => {
        const response = await fetch("/page-result", {method: "POST", headers: {"Content-Type": "application/json", "X-Page-Token": config.pageToken}, body: JSON.stringify({...value, scenario: config.scenario})});
        if (!response.ok) { throw new Error("Fixture evidence rejected: " + await response.text()); }
    };
    let sequence = 0;
    async function execute(action) {
        const requestId = `${config.documentId}-${++sequence}`;
        const message = `${config.message} | ${requestId}`;
        const messageBytes = new TextEncoder().encode(message);
        const asHex = bytes => "0x" + Array.from(bytes, byte => byte.toString(16).padStart(2, "0")).join("");
        const ethereum = window.ethereum;
        const solana = window.bigwallet?.solana || window.solana;
        resultNode.textContent = `Pending ${action}`;
        await report({action, requestId, phase: "started", origin: location.origin, documentId: config.documentId});
        try {
            let result;
            switch (action) {
            case "ethereum-connect": result = await ethereum.request({method: "eth_requestAccounts"}); break;
            case "ethereum-sign": {
                const accounts = await ethereum.request({method: "eth_accounts"});
                result = await ethereum.request({method: "personal_sign", params: [asHex(messageBytes), accounts[0] || config.addresses.ethereum]});
                break;
            }
            case "ethereum-send":
            case "ethereum-send-custom":
            case "ethereum-send-estimated": {
                const accounts = await ethereum.request({method: "eth_accounts"});
                const transaction = {...config.ethereumTransaction, data: asHex(new TextEncoder().encode(requestId)), from: accounts[0] || config.addresses.ethereum};
                if (action === "ethereum-send-custom") { transaction.chainId = "0x" + config.customNetwork.chainId.toString(16); }
                if (action === "ethereum-send-estimated") { for (const field of ["nonce", "gas", "gasPrice"]) { delete transaction[field]; } }
                result = await ethereum.request({method: "eth_sendTransaction", params: [transaction]});
                break;
            }
            case "ethereum-revoke": result = await ethereum.request({method: "wallet_revokePermissions", params: [{eth_accounts: {}}]}); break;
            case "ethereum-chain": result = await ethereum.request({method: "wallet_switchEthereumChain", params: [{chainId: "0xaa36a7"}]}); break;
            case "ethereum-mainnet": result = await ethereum.request({method: "wallet_switchEthereumChain", params: [{chainId: "0x1"}]}); break;
            case "ethereum-permissions": result = await ethereum.request({method: "wallet_requestPermissions", params: [{eth_accounts: {}}]}); break;
            case "ethereum-add-custom": result = await ethereum.request({method: "wallet_addEthereumChain", params: [{chainId: "0x" + config.customNetwork.chainId.toString(16), chainName: config.customNetwork.name, rpcUrls: [config.customNetwork.rpcURL], nativeCurrency: {name: "Fixture Ether", symbol: "ETH", decimals: 18}, blockExplorerUrls: []}]}); break;
            case "ethereum-switch-custom": result = await ethereum.request({method: "wallet_switchEthereumChain", params: [{chainId: "0x" + config.customNetwork.chainId.toString(16)}]}); break;
            case "solana-connect": result = await solana.connect(); break;
            case "solana-sign": {
                const signed = await solana.signMessage(messageBytes);
                result = {publicKey: signed.publicKey.toString(), signature: Array.from(signed.signature)};
                break;
            }
            case "solana-transaction-sign":
            case "solana-batch-sign": {
                const response = await fetch("/page-solana-signing-messages", {method: "POST", headers: {"Content-Type": "application/json", "X-Page-Token": config.pageToken}, body: JSON.stringify({requestId, scenario: config.scenario, origin: location.origin, documentId: config.documentId})});
                if (!response.ok) { throw new Error("Fixture transaction signing request failed"); }
                const {messages} = await response.json();
                const batch = action === "solana-batch-sign";
                const signed = await solana.request({method: batch ? "signAllTransactions" : "signTransaction", params: batch ? {messages} : {message: messages[0]}});
                result = {publicKey: signed.publicKey.toString(), ...(batch ? {signatures: signed.signatures} : {signature: signed.signature})};
                break;
            }
            case "solana-send": {
                const response = await fetch("/page-solana-transaction", {method: "POST", headers: {"Content-Type": "application/json", "X-Page-Token": config.pageToken}, body: JSON.stringify({requestId, scenario: config.scenario, origin: location.origin, documentId: config.documentId})});
                if (!response.ok) { throw new Error("Fixture transaction request failed"); }
                const transaction = await response.json();
                result = await solana.signAndSendTransaction(transaction.transaction, {cluster: "devnet", skipPreflight: false, commitment: "confirmed"});
                break;
            }
            case "rpc-burst":
                result = await Promise.all(Array.from({length: 140}, async (_, index) => {
                    let outcome;
                    try { outcome = {index, ok: true, result: await ethereum.request({method: "eth_blockNumber"})}; }
                    catch (error) { outcome = {index, ok: false, error: {code: error.code, message: error.message, data: error.data}}; }
                    const response = await fetch("/rpc-outcome", {method: "POST", headers: {"Content-Type": "application/json", "X-Page-Token": config.pageToken}, body: JSON.stringify({...outcome, requestId, scenario: config.scenario, origin: location.origin, documentId: config.documentId})});
                    if (!response.ok) { throw new Error("Fixture RPC outcome was rejected"); }
                    return outcome;
                }));
                break;
            case "rpc-error": result = await ethereum.request({method: "eth_getBalance", params: [config.addresses.ethereum, "latest"]}); break;
            case "malformed-requests": {
                const requests = [
                    {method: "personal_sign", params: []},
                    {method: "eth_sendTransaction", params: [null]},
                    {method: "wallet_switchEthereumChain", params: [{chainId: "not-a-chain"}]},
                    {method: "wallet_fixtureUnsupportedMethod", params: []},
                ];
                result = await Promise.all(requests.map(async request => {
                    try { return {method: request.method, ok: true, result: await ethereum.request(request)}; }
                    catch (error) { return {method: request.method, ok: false, code: error.code}; }
                }));
                break;
            }
            case "provider-state": result = {accounts: await ethereum.request({method: "eth_accounts"}), chainId: await ethereum.request({method: "eth_chainId"}), solana: solana?.publicKey?.toString() || null}; break;
            default: throw new Error("Unknown page action");
            }
            const record = {action, requestId, phase: "settled", ok: true, result: serializable(result ?? null), settlements: 1, origin: location.origin, documentId: config.documentId};
            await report(record);
            resultNode.textContent = `Passed ${action}: ${JSON.stringify(record.result)}`;
        } catch (error) {
            const record = {action, requestId, phase: "settled", ok: false, error: {code: Number.isInteger(error?.code) ? error.code : -32603, message: String(error?.message || error)}, settlements: 1, origin: location.origin, documentId: config.documentId};
            await report(record);
            resultNode.textContent = `Rejected ${action}: ${record.error.code}`;
        }
    }
    for (const action of actions) {
        const button = document.createElement("button");
        button.id = action;
        button.setAttribute("aria-label", action);
        button.textContent = action;
        button.style.cssText = "display:block;margin:12px;padding:12px;font-size:18px";
        button.addEventListener("click", () => { void execute(action); });
        document.getElementById("actions").append(button);
    }
    const ready = setInterval(() => {
        if (window.ethereum && (window.bigwallet?.solana || window.solana)) {
            clearInterval(ready);
            document.getElementById("provider-status").textContent = "Providers ready";
            void report({phase: "provider-ready", origin: location.origin, documentId: config.documentId});
        }
    }, 100);
    setTimeout(() => {
        if (!window.ethereum || !(window.bigwallet?.solana || window.solana)) {
            document.getElementById("provider-status").textContent = !window.ethereum && !(window.bigwallet?.solana || window.solana)
                ? "provider-unavailable" : "provider-partial";
        }
    }, 5000);
})();
