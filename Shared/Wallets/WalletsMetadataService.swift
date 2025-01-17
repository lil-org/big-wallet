// ∅ 2025 lil org

import WalletCore

struct WalletsMetadataService {
    
    private init() {}
    
    static func getWalletName(wallet: WalletContainer) -> String? {
        return "" // TODO: implement
    }
    
    static func saveWalletName(_ name: String?, wallet: WalletContainer) {
        // TODO: implement
        // TODO: key by wallet.id
    }
    
    static func getAccountName(wallet: WalletContainer, account: Account) -> String? {
        return "" // TODO: implement
    }
    
    static func saveAccountName(_ name: String?, wallet: WalletContainer, account: Account) {
        // TODO: key by wallet.id account.coin account.derivationPath
        // TODO: implement
    }
    
}
