import Foundation
import CryptoKit
import Darwin

@main
struct ShippedWalletProducer {
    private static let password = "wallet-upgrade-fixture-1.0.98"
    private static let mnemonic = Array(repeating: "abandon", count: 11).joined(separator: " ") + " about"
    private static let ethereumDigest = Data(repeating: 0x42, count: 32)
    private static let solanaMessage = Data("Big Wallet shipped-state recovery fixture v1".utf8)
    private enum Failure: Error { case invalidArguments, assertion(String) }

    static func main() {
        do {
            let arguments = CommandLine.arguments
            guard arguments.count == 4, arguments[1] == "produce", arguments[2] == "--output" else {
                throw Failure.invalidArguments
            }
            try ProducerStorage.configure(output: arguments[3])
            try produce()
            print("Historical wallet fixture produced: 3 wallets, 4 accounts")
        } catch {
            FileHandle.standardError.write(Data("Historical wallet producer failed: \(error)\n".utf8))
            exit(1)
        }
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw Failure.assertion(message) }
    }

    private static func unwrap<Value>(_ value: Value?, _ message: String) throws -> Value {
        guard let value else { throw Failure.assertion(message) }
        return value
    }

    private static func produce() throws {
        let keychain = Keychain.shared
        try require(keychain.createPasswordIfMissing(password), "password insertion")
        try require(!keychain.createPasswordIfMissing("unused replacement"), "duplicate password protection")
        try require(keychain.password == password, "password roundtrip")
        let manager = WalletsManager.shared
        let mnemonicWallet = try manager.addWallet(input: mnemonic, inputPassword: nil)
        let ethereumWallet = try manager.addWallet(input: String(repeating: "01", count: 32), inputPassword: nil)
        let solanaKey = try unwrap(WalletPrivateKey(data: Data(repeating: 2, count: 32)), "Solana fixture key")
        let solanaInput = WalletsManager.privateKeyExportString(privateKey: solanaKey, coin: .solana)
        let solanaWallet = try manager.addWallet(input: solanaInput, inputPassword: nil)
        let hd = try unwrap(mnemonicWallet.key.wallet(password: Data(password.utf8)), "mnemonic derivation")
        let preview = try manager.previewAccounts(hdWallet: hd, page: 0, coin: nil)
        let selected = try ["m/44'/60'/0'/0/1", "m/44'/501'/1'/0'"].map { path in
            try unwrap(preview.first { $0.derivationPath == path }, "advanced account")
        }
        try manager.update(wallet: mnemonicWallet, enabledAccounts: selected)
        let specifications = [
            ("mnemonic", mnemonicWallet.id, "Recovery mnemonic café"),
            ("ethereum", ethereumWallet.id, "Recovery Ethereum key"),
            ("solana", solanaWallet.id, "Recovery Solana key")
        ]
        try require(keychain.getAllWalletsIds() == specifications.map { $0.1 }, "wallet creation order")
        for (fixtureID, walletID, name) in specifications {
            let wallet = try unwrap(manager.currentWallet(id: walletID), "saved wallet")
            WalletsMetadataService.saveWalletName(name, wallet: wallet)
            for account in wallet.accounts {
                let coinName = account.coin == .ethereum ? "Ethereum" : "Solana"
                let accountName = fixtureID == "mnemonic" ? "\(coinName) account 1" : "Imported \(coinName)"
                WalletsMetadataService.saveAccountName(accountName, wallet: wallet, account: account)
            }
        }
        let network = EthereumNetworkFromDapp(chainId: "0x7a69", rpcUrls: ["https://fixture.invalid/rpc"],
            blockExplorerUrls: ["https://fixture.invalid/explorer"],
            nativeCurrency: .init(decimals: 18, name: "Upgrade Coin", symbol: "UPG"), chainName: "Upgrade Fixture")
        let preferences = try unwrap(SharedDefaults.defaults, "shared preference namespace")
        try require(SharedDefaults.addNetwork(network, to: preferences), "custom network insertion")
        let resolved = try unwrap(SharedDefaults.loadCustomNetworkSnapshot(from: preferences).entriesByChainId[31337], "custom network roundtrip")
        try require(resolved.rpcURL.absoluteString == network.defaultRpcUrl, "custom network endpoint")

        let wallets: [[String: Any]] = try specifications.map { fixtureID, walletID, _ in
            let wallet = try unwrap(manager.currentWallet(id: walletID), "reloaded wallet")
            let storedData = try unwrap(keychain.getWalletData(id: walletID), "persisted wallet bytes")
            let accounts: [[String: Any]] = try wallet.accounts.map { account in
                let key = try unwrap(manager.getPrivateKey(walletId: walletID, account: account), "restored account key")
                let input = account.coin == .ethereum ? ethereumDigest : solanaMessage
                let signature = try unwrap(key.sign(digest: input, coin: account.coin), "historical signing")
                let publicKey = key.publicKeyData(coin: account.coin)
                try require(signature.count == (account.coin == .ethereum ? 65 : 64), "signature length")
                try require(WalletCrypto.addressFromPublicKeyData(publicKey, coin: account.coin) == account.address, "derived public identity")
                return [
                    "coin": account.coin.rawValue, "derivation": account.derivation.rawValue,
                    "derivationPath": account.derivationPath, "address": account.address,
                    "publicKey": account.publicKey, "extendedPublicKey": account.extendedPublicKey,
                    "name": WalletsMetadataService.getAccountName(walletId: walletID, account: account) as Any? ?? NSNull(),
                    "privateKeyBackup": try manager.exportPrivateKey(wallet: wallet, account: account),
                    "signing": ["signatureHex": WalletCrypto.hexString(signature), "publicKeyHex": WalletCrypto.hexString(publicKey)]
                ]
            }
            let mnemonicBackup: Any = wallet.isMnemonic ? try manager.exportMnemonic(wallet: wallet) : NSNull()
            return [
                "fixtureID": fixtureID, "walletID": walletID, "isMnemonic": wallet.isMnemonic,
                "name": WalletsMetadataService.getWalletName(wallet: wallet) as Any? ?? NSNull(),
                "walletDataSHA256": WalletCrypto.hexString(Data(SHA256.hash(data: storedData))),
                "mnemonicBackup": mnemonicBackup, "accounts": accounts
            ]
        }
        try require(wallets.count == 3 && wallets.reduce(0, { $0 + (($1["accounts"] as? [[String: Any]])?.count ?? 0) }) == 4,
                    "complete wallet inventory")
        let expectations: [String: Any] = [
            "version": 1, "fixtureID": "shipped-1.0.98-147",
            "baseline": ["commit": "03b1eb841180081063c6a64e5afe58c76d7f3732",
                         "marketingVersion": "1.0.98", "buildVersion": "147", "platform": "macos"],
            "fixturePassword": password, "ethereumDigestHex": WalletCrypto.hexString(ethereumDigest),
            "solanaMessageHex": WalletCrypto.hexString(solanaMessage), "wallets": wallets,
            "networks": [["chainID": 31337, "chainIDHex": network.chainId,
                "name": network.chainName, "symbol": network.nativeCurrency.symbol,
                "decimals": network.nativeCurrency.decimals, "currencyName": network.nativeCurrency.name,
                "rpcURL": resolved.rpcURL.absoluteString, "rpcURLs": network.rpcUrls,
                "blockExplorerURLs": network.blockExplorerUrls]]
        ]
        let data = try JSONSerialization.data(withJSONObject: expectations, options: [.sortedKeys, .prettyPrinted])
        try ProducerStorage.shared.writeOutput(data + Data([10]), named: "expectations.json")
    }
}
