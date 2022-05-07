// Copyright © 2021 Tokenary. All rights reserved.
// Rewrite of Wallet.swift from Trust Wallet Core.

import Foundation
import WalletCore

final class TokenaryWallet: Hashable, Equatable {

    let id: String
    var key: StoredKey

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
    
    func getAccount(password: String, coin: CoinType, derivation: Derivation) throws -> Account {
        let wallet = key.wallet(password: Data(password.utf8))
        guard let account = key.accountForCoinDerivation(coin: coin, derivation: derivation, wallet: wallet) else { throw KeyStore.Error.invalidPassword }
        return account
    }
    
    func getAccounts(password: String, coins: [CoinType]) throws -> [Account] {
        guard let wallet = key.wallet(password: Data(password.utf8)) else { throw KeyStore.Error.invalidPassword }
        return coins.compactMap({ key.accountForCoin(coin: $0, wallet: wallet) })
    }

    func privateKey(password: String, coin: CoinType) throws -> PrivateKey {
        guard let privateKey = key.privateKey(coin: coin, password: Data(password.utf8)) else { throw KeyStore.Error.invalidPassword }
        return privateKey
    }

    func privateKey(password: String, account: Account) throws -> PrivateKey {
        let wallet = key.wallet(password: Data(password.utf8))
        guard let privateKey = wallet?.getKey(coin: account.coin, derivationPath: account.derivationPath) else { throw KeyStore.Error.invalidPassword }
        return privateKey
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: TokenaryWallet, rhs: TokenaryWallet) -> Bool {
        return lhs.id == rhs.id
    }
    
}

extension TokenaryWallet {
    
    var ethereumAddress: String? {
        return accounts.first(where: { $0.coin == .ethereum })?.address
    }
    
    var ethereumPrivateKey: PrivateKey? {
        guard let password = Keychain.shared.password else { return nil }
        return try? privateKey(password: password, coin: .ethereum)
    }
    
    var ethereumPrivateKeyString: String? {
        return ethereumPrivateKey?.data.hexString
    }
    
    var isMnemonic: Bool {
        return key.isMnemonic
    }
    
}
