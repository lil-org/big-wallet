// ∅ 2026 lil org

import WalletCore

struct WalletsMetadataService {
    
    private init() {}
    
    private static var names = Defaults.walletsAndAccountsNames ?? [:]
    
    static func getWalletName(wallet: WalletContainer) -> String? {
        return names[itemKey(walletId: wallet.id, account: nil)]
    }
    
    static func saveWalletName(_ name: String?, wallet: WalletContainer) {
        saveItemName(name, wallet: wallet, account: nil)
    }
    
    static func getAccountName(walletId: String, account: Account) -> String? {
        return names[itemKey(walletId: walletId, account: account)]
    }
    
    static func saveAccountName(_ name: String?, wallet: WalletContainer, account: Account) {
        saveItemName(name, wallet: wallet, account: account)
    }
    
    static func removeMetadataForWallet(_ wallet: WalletContainer) {
        for key in names.keys where key.hasPrefix(wallet.id) {
            names.removeValue(forKey: key)
        }
        Defaults.walletsAndAccountsNames = names
    }
    
    private static func saveItemName(_ name: String?, wallet: WalletContainer, account: Account?) {
        let key = itemKey(walletId: wallet.id, account: account)
        if let name = name, !name.isEmpty {
            names[key] = name
        } else {
            names.removeValue(forKey: key)
        }
        Defaults.walletsAndAccountsNames = names
    }
    
    private static func itemKey(walletId: String, account: Account?) -> String {
        if let account = account {
            return "\(walletId)-\((account.coin.rawValue))-\(account.derivationPath)"
        } else {
            return walletId
        }
    }
    
}
