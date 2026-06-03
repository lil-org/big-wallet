// ∅ 2026 lil org


struct WalletsMetadataService {

    private init() {}

    private static var names = Defaults.walletsAndAccountsNames ?? [:]

    static func reload() {
        names = currentNames()
    }

    static func getWalletName(wallet: WalletContainer) -> String? {
        return names[itemKey(walletId: wallet.id, account: nil)]
    }

    static func saveWalletName(_ name: String?, wallet: WalletContainer) {
        saveItemName(name, wallet: wallet, account: nil)
    }

    static func getAccountName(walletId: String, account: WalletAccount) -> String? {
        return names[itemKey(walletId: walletId, account: account)]
    }

    static func saveAccountName(_ name: String?, wallet: WalletContainer, account: WalletAccount) {
        saveItemName(name, wallet: wallet, account: account)
    }

    static func removeMetadataForWallet(_ wallet: WalletContainer, postChange: Bool = true) {
        names = currentNames()
        for key in names.keys.filter({ isMetadataKey($0, forWalletId: wallet.id) }) {
            names.removeValue(forKey: key)
        }
        saveNames(postChange: postChange)
    }

    private static func saveItemName(_ name: String?, wallet: WalletContainer, account: WalletAccount?) {
        names = currentNames()
        let key = itemKey(walletId: wallet.id, account: account)
        if let name = name, !name.isEmpty {
            names[key] = name
        } else {
            names.removeValue(forKey: key)
        }
        saveNames()
    }

    private static func saveNames(postChange: Bool = true) {
        Defaults.walletsAndAccountsNames = names
        if postChange {
            WalletStoreSync.postLocalAndExternalChange(defaultsAlreadySynchronized: true)
        }
    }

    private static func itemKey(walletId: String, account: WalletAccount?) -> String {
        if let account = account {
            return "\(walletId)-\((account.coin.rawValue))-\(account.derivationPath)"
        } else {
            return walletId
        }
    }

    private static func isMetadataKey(_ key: String, forWalletId walletId: String) -> Bool {
        return key == walletId || key.hasPrefix("\(walletId)-")
    }

    private static func currentNames() -> [String: String] {
        Defaults.synchronize()
        return Defaults.walletsAndAccountsNames ?? [:]
    }

}
