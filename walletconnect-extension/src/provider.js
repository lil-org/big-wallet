import WalletConnectProvider from "@walletconnect/web3-provider";
import provider from "eth-provider";

const wcProvider = new WalletConnectProvider({
  infuraId: "8b014620351a4cbe814220743619df5b",
});

const fallbackProvider = provider([
  "https://mainnet.infura.io/v3/8b014620351a4cbe814220743619df5b",
]);

fallbackProvider.enable = () => {
  window.ethereum = wcProvider;
  return wcProvider.enable();
};

window.ethereum = fallbackProvider;