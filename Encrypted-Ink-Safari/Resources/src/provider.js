import WalletConnectProvider from "@walletconnect/web3-provider";
import provider from "eth-provider";

const wcProvider = new WalletConnectProvider({
  rpc: {
    1: "https://mainnet.infura.io/v3/8b014620351a4cbe814220743619df5b",
    56: "https://bsc-dataseed.binance.org",
    2020: "https://api.roninchain.com/rpc/",
    10: "https://mainnet.optimism.io"
  }
});

const fallbackProvider = provider([""]);

fallbackProvider.enable = () => {
  window.ethereum = wcProvider;
  return wcProvider.enable();
};

window.ethereum = fallbackProvider;
