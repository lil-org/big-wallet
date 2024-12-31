// ∅ 2025 lil org
// Rewrite of Wallet.swift from Trust Wallet Core.

import Foundation
import WalletCore

final class WalletContainer: Hashable, Equatable {

    let id: String
    var key: StoredKey
    
    var isMnemonic: Bool {
        return key.isMnemonic
    }

    var accounts: [Account] {
        return (0..<key.accountCount).compactMap({ key.account(index: $0) })
    }
    
    init(id: String, key: StoredKey) {
        self.id = id
        self.key = key
    }
    
    func getAccount(password: String, coin: CoinType) throws -> Account {
        let wallet = key.wallet(password: Data(password.utf8))
        guard let account = key.accountForCoin(coin: coin, wallet: wallet) else { throw KeyStore.Error.invalidPassword }
        return account
    }

    func privateKey(password: String, account: Account) throws -> PrivateKey {
        if isMnemonic {
            let wallet = key.wallet(password: Data(password.utf8))
            guard let privateKey = wallet?.getKey(coin: account.coin, derivationPath: account.derivationPath) else { throw KeyStore.Error.invalidPassword }
            return privateKey
        } else {
            guard let privateKey = key.privateKey(coin: account.coin, password: Data(password.utf8)) else { throw KeyStore.Error.invalidPassword }
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
