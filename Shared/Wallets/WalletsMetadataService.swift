// ∅ 2026 lil org

import Synchronization

struct WalletsMetadataService {
    private static let names = Mutex(Defaults.walletsAndAccountsNames ?? [:])

    private init() {}

    static func reload() {
        names.withLock { $0 = currentNames() }
    }

    static func getWalletName(wallet: WalletSnapshot) -> String? {
        names.withLock { $0[itemKey(walletId: wallet.id, account: nil)] }
    }

    static func saveWalletName(_ name: String?, wallet: WalletSnapshot) {
        saveItemName(name, wallet: wallet, account: nil)
    }

    static func getAccountName(walletId: String, account: WalletAccount) -> String? {
        names.withLock { $0[itemKey(walletId: walletId, account: account)] }
    }

    static func saveAccountName(_ name: String?, wallet: WalletSnapshot, account: WalletAccount) {
        saveItemName(name, wallet: wallet, account: account)
    }

    static func removeMetadataForWallet(_ wallet: WalletSnapshot, postChange: Bool = true) {
        updateNames(postChange: postChange) { names in
            for key in names.keys.filter({ isMetadataKey($0, forWalletId: wallet.id) }) {
                names.removeValue(forKey: key)
            }
        }
    }

    static func removeMetadataForAccounts(walletId: String, accounts: [WalletAccount], postChange: Bool = true) {
        updateNames(postChange: postChange) { names in
            for account in accounts {
                names.removeValue(forKey: itemKey(walletId: walletId, account: account))
            }
        }
    }

    private static func saveItemName(_ name: String?, wallet: WalletSnapshot, account: WalletAccount?) {
        updateNames { names in
            let key = itemKey(walletId: wallet.id, account: account)
            if let name, !name.isEmpty {
                names[key] = name
            } else {
                names.removeValue(forKey: key)
            }
        }
    }

    private static func updateNames(postChange: Bool = true, _ update: (inout [String: String]) -> Void) {
        names.withLock { names in
            names = currentNames()
            update(&names)
            Defaults.walletsAndAccountsNames = names
        }
        if postChange {
            WalletStoreSync.postLocalAndExternalChange(defaultsAlreadySynchronized: true)
        }
    }

    private static func itemKey(walletId: String, account: WalletAccount?) -> String {
        guard let account else { return walletId }
        return "\(walletId)-\(account.coin.rawValue)-\(account.derivationPath)"
    }

    private static func isMetadataKey(_ key: String, forWalletId walletId: String) -> Bool {
        key == walletId || key.hasPrefix("\(walletId)-")
    }

    private static func currentNames() -> [String: String] {
        Defaults.synchronize()
        return Defaults.walletsAndAccountsNames ?? [:]
    }
}
