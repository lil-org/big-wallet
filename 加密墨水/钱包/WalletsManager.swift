// Copyright © 2021 guanlong huang. All rights reserved.
// Rewrite of KeyStore.swift from Trust Wallet Core.

import Foundation
import WalletCore

final class WalletsManager {

    enum Error: Swift.Error {
        case keychainAccessFailure
        case invalidInput
    }
    
    enum InputValidationResult {
        case valid, invalid, requiresPassword
    }
    
    static let shared = WalletsManager()
    private let keychain = Keychain.shared
    private(set) var wallets = [InkWallet]()

    private init() {}

    func start() {
        try? load()
        try? migrateFromLegacyIfNeeded()
    }
    
    func validateWalletInput(_ input: String) -> InputValidationResult {
        if Mnemonic.isValid(mnemonic: input) {
            return .valid
        } else if let data = Data(hexString: input) {
            return PrivateKey.isValid(data: data, curve: CoinType.ethereum.curve) ? .valid : .invalid
        } else {
            return input.maybeJSON ? .requiresPassword : .invalid
        }
    }
    
    func createWallet() throws -> InkWallet {
        guard let password = keychain.password else { throw Error.keychainAccessFailure }
        return try createWallet(name: defaultWalletName, password: password, coin: .ethereum)
    }
    
    func getWallet(id: String) -> InkWallet? {
        return wallets.first(where: { $0.id == id })
    }
    
    func addWallet(input: String, inputPassword: String?) throws -> InkWallet {
        guard let password = keychain.password else { throw Error.keychainAccessFailure }
        let name = defaultWalletName
        let coin = CoinType.ethereum
        if Mnemonic.isValid(mnemonic: input) {
            return try importMnemonic(input, name: name, encryptPassword: password, coin: coin)
        } else if let data = Data(hexString: input), PrivateKey.isValid(data: data, curve: coin.curve), let privateKey = PrivateKey(data: data) {
            return try importPrivateKey(privateKey, name: name, password: password, coin: coin)
        } else if input.maybeJSON, let inputPassword = inputPassword, let json = input.data(using: .utf8) {
            return try importJSON(json, name: name, password: inputPassword, newPassword: password, coin: coin)
        } else {
            throw Error.invalidInput
        }
    }
    
    private func createWallet(name: String, password: String, coin: CoinType) throws -> InkWallet {
        let key = StoredKey(name: name, password: Data(password.utf8))
        let id = makeNewWalletId()
        let wallet = InkWallet(id: id, key: key)
        _ = try wallet.getAccount(password: password, coin: coin)
        wallets.append(wallet)
        try save(wallet: wallet)
        return wallet
    }

    private func importJSON(_ json: Data, name: String, password: String, newPassword: String, coin: CoinType) throws -> InkWallet {
        guard let key = StoredKey.importJSON(json: json) else { throw KeyStore.Error.invalidKey }
        guard let data = key.decryptPrivateKey(password: Data(password.utf8)) else { throw KeyStore.Error.invalidPassword }
        if let mnemonic = checkMnemonic(data) { return try self.importMnemonic(mnemonic, name: name, encryptPassword: newPassword, coin: coin) }
        guard let privateKey = PrivateKey(data: data) else { throw KeyStore.Error.invalidKey }
        return try self.importPrivateKey(privateKey, name: name, password: newPassword, coin: coin)
    }

    private func checkMnemonic(_ data: Data) -> String? {
        guard let mnemonic = String(data: data, encoding: .ascii), Mnemonic.isValid(mnemonic: mnemonic) else { return nil }
        return mnemonic
    }

    private func importPrivateKey(_ privateKey: PrivateKey, name: String, password: String, coin: CoinType) throws -> InkWallet {
        guard let newKey = StoredKey.importPrivateKey(privateKey: privateKey.data, name: name, password: Data(password.utf8), coin: coin) else { throw KeyStore.Error.invalidKey }
        let id = makeNewWalletId()
        let wallet = InkWallet(id: id, key: newKey)
        _ = try wallet.getAccount(password: password, coin: coin)
        wallets.append(wallet)
        try save(wallet: wallet)
        return wallet
    }

    private func importMnemonic(_ mnemonic: String, name: String, encryptPassword: String, coin: CoinType) throws -> InkWallet {
        guard let key = StoredKey.importHDWallet(mnemonic: mnemonic, name: name, password: Data(encryptPassword.utf8), coin: coin) else { throw KeyStore.Error.invalidMnemonic }
        let id = makeNewWalletId()
        let wallet = InkWallet(id: id, key: key)
        _ = try wallet.getAccount(password: encryptPassword, coin: coin)
        wallets.append(wallet)
        try save(wallet: wallet)
        return wallet
    }

    func exportPrivateKey(wallet: InkWallet) throws -> Data {
        guard let password = keychain.password else { throw Error.keychainAccessFailure }
        guard let key = wallet.key.decryptPrivateKey(password: Data(password.utf8)) else { throw KeyStore.Error.invalidPassword }
        return key
    }

    func exportMnemonic(wallet: InkWallet) throws -> String {
        guard let password = keychain.password else { throw Error.keychainAccessFailure }
        guard let mnemonic = wallet.key.decryptMnemonic(password: Data(password.utf8)) else { throw KeyStore.Error.invalidPassword }
        return mnemonic
    }

    func update(wallet: InkWallet, password: String, newPassword: String) throws {
        try update(wallet: wallet, password: password, newPassword: newPassword, newName: wallet.key.name)
    }

    func update(wallet: InkWallet, password: String, newName: String) throws {
        try update(wallet: wallet, password: password, newPassword: password, newName: newName)
    }

    func delete(wallet: InkWallet) throws {
        guard let password = keychain.password else { throw Error.keychainAccessFailure }
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
    
    private func load() throws {
        let ids = keychain.getAllWalletsIds()
        for id in ids {
            guard let data = keychain.getWalletData(id: id), let key = StoredKey.importJSON(json: data) else { continue }
            let wallet = InkWallet(id: id, key: key)
            wallets.append(wallet)
        }
    }
    
    private func migrateFromLegacyIfNeeded() throws {
        let legacyAccountsWithKeys = try keychain.getLegacyAccounts()
        guard !legacyAccountsWithKeys.isEmpty, let password = keychain.password else { return }
        for legacyAccount in legacyAccountsWithKeys {
            if let data = Data(hexString: legacyAccount.privateKey), let privateKey = PrivateKey(data: data) {
                _ = try importPrivateKey(privateKey, name: defaultWalletName, password: password, coin: .ethereum)
            }
        }
        try keychain.removeLegacyAccounts()
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

    private func save(wallet: InkWallet) throws {
        guard let data = wallet.key.exportJSON() else { throw KeyStore.Error.invalidPassword }
        try keychain.saveWallet(id: wallet.id, data: data)
    }
    
    private var defaultWalletName = ""
    
    private func makeNewWalletId() -> String {
        let uuid = UUID().uuidString
        let date = Date().timeIntervalSince1970
        let walletId = "\(uuid)-\(date)"
        return walletId
    }
    
}
