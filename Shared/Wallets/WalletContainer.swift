// ∅ 2026 lil org
// Rewrite of Wallet.swift from Trust Wallet Core.

import Foundation

final class WalletContainer: Hashable, Equatable {

    let id: String
    var key: WalletStoredKey
    
    var isMnemonic: Bool {
        return key.isMnemonic
    }

    var accounts: [WalletAccount] {
        return (0..<key.accountCount).compactMap({ key.account(index: $0) })
    }
    
    init(id: String, key: WalletStoredKey) {
        self.id = id
        self.key = key
    }
    
    func getAccount(password: String, coin: WalletCoin) throws -> WalletAccount {
        let wallet = key.wallet(password: Data(password.utf8))
        guard let account = key.accountForCoin(coin: coin, wallet: wallet) else { throw WalletKeyStoreError.invalidPassword }
        return account
    }

    func privateKey(password: String, account: WalletAccount) throws -> WalletPrivateKey {
        if isMnemonic {
            let wallet = key.wallet(password: Data(password.utf8))
            guard let privateKey = wallet?.getKey(coin: account.coin, derivationPath: account.derivationPath) else { throw WalletKeyStoreError.invalidPassword }
            return privateKey
        } else {
            guard let privateKey = key.privateKey(coin: account.coin, password: Data(password.utf8)) else { throw WalletKeyStoreError.invalidPassword }
            return privateKey
        }
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: WalletContainer, rhs: WalletContainer) -> Bool {
        return lhs.id == rhs.id
    }
    
}
