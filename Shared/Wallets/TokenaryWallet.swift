// Copyright © 2021 Tokenary. All rights reserved.
// Rewrite of Wallet.swift from Trust Wallet Core.

import Foundation
import WalletCore

final class TokenaryWallet: Hashable, Equatable {

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

    func yo(password: String) {
        guard let wallet = key.wallet(password: Data(password.utf8)) else { return }
        let coin = CoinType.ethereum
        for i in 0...20 {
            let dp = DerivationPath(purpose: .bip44, coin: CoinType.ethereum.slip44Id, account: 0, change: 0, address: UInt32(i))
            let xpub = wallet.getExtendedPublicKey(purpose: coin.purpose, coin: coin, version: .xpub)
            guard let pubkey = HDWallet.getPublicKeyFromExtended(extended: xpub, coin: coin, derivationPath: dp.description) else { continue }
            let address = coin.deriveAddressFromPublicKey(publicKey: pubkey)
            if i != 0 {
                key.removeAccountForCoinDerivationPath(coin: coin, derivationPath: dp.description)
            } else if i > 100 {
                key.addAccount(address: address, coin: coin, derivationPath: dp.description, publicKey: pubkey.description, extendedPublicKey: xpub)
            }
        }
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

    static func == (lhs: TokenaryWallet, rhs: TokenaryWallet) -> Bool {
        return lhs.id == rhs.id
    }
    
}
