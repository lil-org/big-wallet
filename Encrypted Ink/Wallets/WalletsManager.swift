// Copyright © 2021 Encrypted Ink. All rights reserved.
// Rewrite of KeyStore.swift from Trust Wallet Core.

import Foundation
import WalletCore

final class WalletsManager {

    static let shared = WalletsManager()
    private let keychain = Keychain.shared
    private(set) var wallets = [InkWallet]()

    private init() {}

    func start() {
        try? load()
    }
    
    private func load() throws {
        let ids = keychain.getAllWalletsIds()
        for id in ids {
            guard let data = keychain.getWalletData(id: id), let key = StoredKey.importJSON(json: data) else { continue }
            let wallet = InkWallet(id: id, key: key)
            wallets.append(wallet)
        }
    }

    func createWallet(name: String, password: String, coin: CoinType) throws -> InkWallet {
        let key = StoredKey(name: name, password: Data(password.utf8))
        let id = makeNewWalletId()
        let wallet = InkWallet(id: id, key: key)
        _ = try wallet.getAccount(password: password, coin: coin)
        wallets.append(wallet)
        try save(wallet: wallet)
        return wallet
    }

    func importJSON(_ json: Data, name: String, password: String, newPassword: String, coin: CoinType) throws -> InkWallet {
        guard let key = StoredKey.importJSON(json: json) else { throw KeyStore.Error.invalidKey }
        guard let data = key.decryptPrivateKey(password: Data(password.utf8)) else { throw KeyStore.Error.invalidPassword }
        if let mnemonic = checkMnemonic(data) { return try self.importMnemonic(mnemonic, name: name, encryptPassword: newPassword, coin: coin) }
        guard let privateKey = PrivateKey(data: data) else { throw KeyStore.Error.invalidKey }
        return try self.importPrivateKey(privateKey, name: name, password: newPassword, coin: coin)
    }

    func checkMnemonic(_ data: Data) -> String? {
        guard let mnemonic = String(data: data, encoding: .ascii), Mnemonic.isValid(mnemonic: mnemonic) else { return nil }
        return mnemonic
    }

    func importPrivateKey(_ privateKey: PrivateKey, name: String, password: String, coin: CoinType) throws -> InkWallet {
        guard let newKey = StoredKey.importPrivateKey(privateKey: privateKey.data, name: name, password: Data(password.utf8), coin: coin) else { throw KeyStore.Error.invalidKey }
        let id = makeNewWalletId()
        let wallet = InkWallet(id: id, key: newKey)
        _ = try wallet.getAccount(password: password, coin: coin)
        wallets.append(wallet)
        try save(wallet: wallet)
        return wallet
    }

    func importMnemonic(_ mnemonic: String, name: String, encryptPassword: String, coin: CoinType) throws -> InkWallet {
        guard let key = StoredKey.importHDWallet(mnemonic: mnemonic, name: name, password: Data(encryptPassword.utf8), coin: coin) else { throw KeyStore.Error.invalidMnemonic }
        let id = makeNewWalletId()
        let wallet = InkWallet(id: id, key: key)
        _ = try wallet.getAccount(password: encryptPassword, coin: coin)
        wallets.append(wallet)
        try save(wallet: wallet)
        return wallet
    }

    func exportPrivateKey(wallet: InkWallet, password: String) throws -> Data {
        guard let key = wallet.key.decryptPrivateKey(password: Data(password.utf8)) else { throw KeyStore.Error.invalidPassword }
        return key
    }

    func exportMnemonic(wallet: InkWallet, password: String) throws -> String {
        guard let mnemonic = wallet.key.decryptMnemonic(password: Data(password.utf8)) else { throw KeyStore.Error.invalidPassword }
        return mnemonic
    }

    func update(wallet: InkWallet, password: String, newPassword: String) throws {
        try update(wallet: wallet, password: password, newPassword: newPassword, newName: wallet.key.name)
    }

    func update(wallet: InkWallet, password: String, newName: String) throws {
        try update(wallet: wallet, password: password, newPassword: password, newName: newName)
    }

    private func update(wallet: InkWallet, password: String, newPassword: String, newName: String) throws {
        guard let index = wallets.firstIndex(of: wallet) else { throw KeyStore.Error.accountNotFound }
        guard var privateKeyData = wallet.key.decryptPrivateKey(password: Data(password.utf8)) else { throw KeyStore.Error.invalidPassword }
        defer { privateKeyData.resetBytes(in: 0 ..< privateKeyData.count) }
        let coins = wallet.accounts.map({ $0.coin })
        guard !coins.isEmpty else { throw KeyStore.Error.accountNotFound }
        
        if let mnemonic = checkMnemonic(privateKeyData),
            let key = StoredKey.importHDWallet(mnemonic: mnemonic, name: newName, password: Data(newPassword.utf8), coin: coins[0]) {
            wallets[index].key = key
        } else if let key = StoredKey.importPrivateKey(
                privateKey: privateKeyData, name: newName, password: Data(newPassword.utf8), coin: coins[0]) {
            wallets[index].key = key
        } else {
            throw KeyStore.Error.invalidKey
        }
        
        _ = try wallets[index].getAccounts(password: newPassword, coins: coins)
        try save(wallet: wallets[index])
    }

    func delete(wallet: InkWallet, password: String) throws {
        guard let index = wallets.firstIndex(of: wallet) else { throw KeyStore.Error.accountNotFound }
        guard var privateKey = wallet.key.decryptPrivateKey(password: Data(password.utf8)) else { throw KeyStore.Error.invalidKey }
        defer { privateKey.resetBytes(in: 0..<privateKey.count) }
        wallets.remove(at: index)
        try keychain.removeWallet(id: wallet.id)
    }

    func destroy() throws {
        wallets.removeAll(keepingCapacity: false)
        try keychain.removeAllWallets()
    }

    private func save(wallet: InkWallet) throws {
        guard let data = wallet.key.exportJSON() else { throw KeyStore.Error.invalidPassword }
        try keychain.saveWallet(id: wallet.id, data: data)
    }
    
    private func makeNewWalletId() -> String {
        let uuid = UUID().uuidString
        let date = Date().timeIntervalSince1970
        let walletId = "\(uuid)-\(date)"
        return walletId
    }
    
}
