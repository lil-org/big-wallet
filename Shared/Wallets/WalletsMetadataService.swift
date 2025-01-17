// ∅ 2025 lil org

import WalletCore

struct WalletsMetadataService {
    
    private init() {}
    
    private static var names = Defaults.walletsAndAccountsNames ?? [:]
    
    static func getWalletName(wallet: WalletContainer) -> String? {
        return names[itemKey(wallet: wallet, account: nil)]
    }
    
    static func saveWalletName(_ name: String?, wallet: WalletContainer) {
        saveItemName(name, wallet: wallet, account: nil)
    }
    
    static func getAccountName(wallet: WalletContainer, account: Account) -> String? {
        return names[itemKey(wallet: wallet, account: account)]
    }
    
    static func saveAccountName(_ name: String?, wallet: WalletContainer, account: Account) {
        saveItemName(name, wallet: wallet, account: account)
    }
    
    private static func saveItemName(_ name: String?, wallet: WalletContainer, account: Account?) {
        let key = itemKey(wallet: wallet, account: account)
        if let name = name, !name.isEmpty {
            names[key] = name
        } else {
            names.removeValue(forKey: key)
        }
        Defaults.walletsAndAccountsNames = names
    }
    
    private static func itemKey(wallet: WalletContainer, account: Account?) -> String {
        if let account = account {
            return "\(wallet.id)-\((account.coin.rawValue))-\(account.derivationPath)"
        } else {
            return wallet.id
        }
    }
    
}
