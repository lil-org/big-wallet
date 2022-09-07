// Copyright © 2021 Tokenary. All rights reserved.
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
    private(set) var wallets = [TokenaryWallet]()
    
    private let fileManager = FileManager.default
    private let walletsMetadataURL: URL
    private var walletsMetadata: WalletsMetadata

    private init() {
        let baseURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: "")
        let walletsMetadataURL = baseURL.appendingPathComponent("wallets_metadata.json")
        self.walletsMetadataURL = walletsMetadataURL
        if fileManager.fileExists(atPath: walletsMetadataURL.path),
           let data = try? Data(contentsOf: walletsMetadataURL),
           let walletsMetadata = try? JSONDecoder().decode(WalletsMetadata.self, from: data) {
            self.walletsMetadata = walletsMetadata
        } else {
            self.walletsMetadata = WalletsMetadata()
        }
    }

    func start() {
        try? loadWallets()
        updateWalletsMetadata()
    }
    
    private func updateWalletsMetadata() {
        for wallet in wallets {
            // TODO: explicitly check if successfully received external accounts before
            guard wallet.metadata?.externalAccounts.isEmpty != false else { continue }
            let nearAccounts = wallet.accounts.compactMap { ($0.isDerived && $0.coin == .near) ? $0 : nil }
            for account in nearAccounts {
                guard let derivedAccount = account.derivedAccount else { continue }
                Near.shared.getAccountIds(implicitAccountId: account.address) { [weak self] names in
                    guard let names = names, !names.isEmpty else { return }
                    let externalAccounts = names.map { ExternalAccount(parentAccount: derivedAccount, nearName: $0, isHidden: false) }
                    var metadata = self?.walletsMetadata.forWallet[wallet.id] ?? WalletMetadata()
                    metadata.externalAccounts = externalAccounts // TODO: should not override external accounts for other networks
                    wallet.updateMetadata(metadata)
                    wallet.updateAccounts()
                    self?.walletsMetadata.forWallet[wallet.id] = metadata
                    try? self?.saveWalletsMetadata()
                    self?.postWalletsChangedNotification()
                }
            }
        }
    }
    
    private func saveWalletsMetadata() throws {
        let data = try JSONEncoder().encode(walletsMetadata)
        try data.write(to: walletsMetadataURL)
    }
    
    #if os(macOS)
    func migrateFromLegacyIfNeeded() {
        guard !Defaults.didMigrateKeychainFromTokenaryV1 else { return }
        let legacyKeystores = keychain.getLegacyKeystores()
        if !legacyKeystores.isEmpty, let legacyPassword = keychain.legacyPassword {
            keychain.save(password: legacyPassword)
            for keystore in legacyKeystores {
                _ = try? importJSON(keystore,
                                    name: defaultWalletName,
                                    password: legacyPassword,
                                    newPassword: legacyPassword,
                                    coin: .ethereum,
                                    onlyToKeychain: true)
            }
            Defaults.shouldPromptSafariForLegacyUsers = true
        }
        Defaults.didMigrateKeychainFromTokenaryV1 = true
    }
    #endif
    
    func validateWalletInput(_ input: String) -> InputValidationResult {
        if Mnemonic.isValid(mnemonic: input) {
            return .valid
        } else if let data = Data(hexString: input) {
            return PrivateKey.isValid(data: data, curve: CoinType.ethereum.curve) ? .valid : .invalid
        } else {
            return input.maybeJSON ? .requiresPassword : .invalid
        }
    }
    
    func createWallet() throws -> TokenaryWallet {
        guard let password = keychain.password else { throw Error.keychainAccessFailure }
        return try createWallet(name: defaultWalletName, password: password)
    }
    
    func getWallet(id: String) -> TokenaryWallet? {
        return wallets.first(where: { $0.id == id })
    }
    
    func addWallet(input: String, inputPassword: String?) throws -> TokenaryWallet {
        guard let password = keychain.password else { throw Error.keychainAccessFailure }
        let name = defaultWalletName
        let defaultCoin = CoinType.ethereum
        if Mnemonic.isValid(mnemonic: input) {
            return try importMnemonic(input, name: name, encryptPassword: password)
        } else if let data = Data(hexString: input), PrivateKey.isValid(data: data, curve: defaultCoin.curve), let privateKey = PrivateKey(data: data) {
            return try importPrivateKey(privateKey, name: name, password: password, coin: defaultCoin, onlyToKeychain: false)
        } else if input.maybeJSON, let inputPassword = inputPassword, let json = input.data(using: .utf8) {
            return try importJSON(json, name: name, password: inputPassword, newPassword: password, coin: defaultCoin, onlyToKeychain: false)
        } else {
            throw Error.invalidInput
        }
    }
    
    func getSpecificAccount(coin: CoinType, address: String) -> SpecificWalletAccount? {
        for wallet in wallets {
            if let account = wallet.accounts.first(where: { $0.coin == coin && $0.address.lowercased() == address.lowercased() }) {
                return SpecificWalletAccount(walletId: wallet.id, account: account)
            }
        }
        return nil
    }
    
    func suggestedAccounts(coin: CoinType) -> [SpecificWalletAccount] {
        for wallet in wallets {
            if let account = wallet.accounts.first(where: { $0.coin == coin }) {
                return [SpecificWalletAccount(walletId: wallet.id, account: account)]
            }
        }
        return []
    }
    
    private func createWallet(name: String, password: String) throws -> TokenaryWallet {
        let key = StoredKey(name: name, password: Data(password.utf8))
        let id = makeNewWalletId()
        let wallet = TokenaryWallet(id: id, key: key, metadata: nil)
        for coinDerivation in CoinDerivation.enabledByDefaultCoinDerivations {
            try wallet.createAccount(password: password, coin: coinDerivation.coin, derivation: coinDerivation.derivation)
        }
        
        wallet.updateAccounts()
        wallets.append(wallet)
        try save(wallet: wallet, isUpdate: false)
        return wallet
    }

    private func importJSON(_ json: Data, name: String, password: String, newPassword: String, coin: CoinType, onlyToKeychain: Bool) throws -> TokenaryWallet {
        guard let key = StoredKey.importJSON(json: json) else { throw KeyStore.Error.invalidKey }
        guard let data = key.decryptPrivateKey(password: Data(password.utf8)) else { throw KeyStore.Error.invalidPassword }
        if let mnemonic = checkMnemonic(data) { return try self.importMnemonic(mnemonic, name: name, encryptPassword: newPassword) }
        guard let privateKey = PrivateKey(data: data) else { throw KeyStore.Error.invalidKey }
        return try self.importPrivateKey(privateKey, name: name, password: newPassword, coin: coin, onlyToKeychain: onlyToKeychain)
    }

    private func checkMnemonic(_ data: Data) -> String? {
        guard let mnemonic = String(data: data, encoding: .ascii), Mnemonic.isValid(mnemonic: mnemonic) else { return nil }
        return mnemonic
    }

    private func importPrivateKey(_ privateKey: PrivateKey, name: String, password: String, coin: CoinType, onlyToKeychain: Bool) throws -> TokenaryWallet {
        guard let newKey = StoredKey.importPrivateKey(privateKey: privateKey.data, name: name, password: Data(password.utf8), coin: coin) else { throw KeyStore.Error.invalidKey }
        let id = makeNewWalletId()
        let wallet = TokenaryWallet(id: id, key: newKey, metadata: nil)
        try wallet.createAccount(password: password, coin: coin)
        wallet.updateAccounts()
        if !onlyToKeychain {
            wallets.append(wallet)
        }
        try save(wallet: wallet, isUpdate: false)
        return wallet
    }

    private func importMnemonic(_ mnemonic: String, name: String, encryptPassword: String) throws -> TokenaryWallet {
        let coinDerivations = CoinDerivation.enabledByDefaultCoinDerivations
        guard let key = StoredKey.importHDWallet(mnemonic: mnemonic, name: name, password: Data(encryptPassword.utf8), coin: coinDerivations[0].coin) else { throw KeyStore.Error.invalidMnemonic }
        let id = makeNewWalletId()
        let wallet = TokenaryWallet(id: id, key: key, metadata: nil)
        
        for coinDerivation in coinDerivations {
            try wallet.createAccount(password: encryptPassword, coin: coinDerivation.coin, derivation: coinDerivation.derivation)
        }
        
        wallet.updateAccounts()
        wallets.append(wallet)
        try save(wallet: wallet, isUpdate: false)
        return wallet
    }

    func exportPrivateKey(wallet: TokenaryWallet) throws -> Data {
        guard let password = keychain.password else { throw Error.keychainAccessFailure }
        guard let key = wallet.key.decryptPrivateKey(password: Data(password.utf8)) else { throw KeyStore.Error.invalidPassword }
        return key
    }

    func exportMnemonic(wallet: TokenaryWallet) throws -> String {
        guard let password = keychain.password else { throw Error.keychainAccessFailure }
        guard let mnemonic = wallet.key.decryptMnemonic(password: Data(password.utf8)) else { throw KeyStore.Error.invalidPassword }
        return mnemonic
    }

    func update(wallet: TokenaryWallet, newPassword: String) throws {
        guard let password = keychain.password else { throw Error.keychainAccessFailure }
        try update(wallet: wallet, password: password, newPassword: newPassword, newName: wallet.key.name)
    }

    func update(wallet: TokenaryWallet, newName: String) throws {
        guard let password = keychain.password else { throw Error.keychainAccessFailure }
        try update(wallet: wallet, password: password, newPassword: password, newName: newName)
    }

    func delete(wallet: TokenaryWallet) throws {
        guard let password = keychain.password else { throw Error.keychainAccessFailure }
        guard let index = wallets.firstIndex(of: wallet) else { throw KeyStore.Error.accountNotFound }
        guard var privateKey = wallet.key.decryptPrivateKey(password: Data(password.utf8)) else { throw KeyStore.Error.invalidKey }
        defer { privateKey.resetBytes(in: 0..<privateKey.count) }
        wallets.remove(at: index)
        try keychain.removeWallet(id: wallet.id)
        walletsMetadata.forWallet.removeValue(forKey: wallet.id)
        postWalletsChangedNotification()
        try saveWalletsMetadata()
    }

    func destroy() throws {
        walletsMetadata = WalletsMetadata()
        wallets.removeAll(keepingCapacity: false)
        try keychain.removeAllWallets()
        try saveWalletsMetadata()
    }
    
    private func loadWallets() throws {
        let ids = keychain.getAllWalletsIds()
        for id in ids {
            guard let data = keychain.getWalletData(id: id), let key = StoredKey.importJSON(json: data) else { continue }
            let wallet = TokenaryWallet(id: id, key: key, metadata: walletsMetadata.forWallet[id])
            wallets.append(wallet)
        }
    }
    
    // TODO: support updating not only coin derivations, but additional accounts as well
    func update(wallet: TokenaryWallet, coinDerivations: [CoinDerivation], externalAccounts: [ExternalAccount]) throws {
        guard let password = keychain.password else { throw Error.keychainAccessFailure }
        
        for account in wallet.accounts {
            wallet.key.removeAccountForCoin(coin: account.coin)
        }
        
        for coinDerivation in coinDerivations {
            try wallet.createAccount(password: password, coin: coinDerivation.coin, derivation: coinDerivation.derivation)
        }
        
        wallet.updateAccounts()
        try save(wallet: wallet, isUpdate: true)
    }
    
    func update(wallet: TokenaryWallet, removeAccounts toRemove: [TokenaryAccount]) throws {
        for account in toRemove {
            if account.isDerived {
                wallet.key.removeAccountForCoinDerivationPath(coin: account.coin, derivationPath: account.derivationPath)
            } else if var metadata = walletsMetadata.forWallet[wallet.id],
                      let index = metadata.externalAccounts.firstIndex(where: { $0.address == account.address }) {
                metadata.externalAccounts[index].isHidden = true
                walletsMetadata.forWallet[wallet.id] = metadata
                wallet.updateMetadata(metadata)
            }
        }
        
        wallet.updateAccounts()
        try save(wallet: wallet, isUpdate: true)
        try saveWalletsMetadata()
    }
    
    private func update(wallet: TokenaryWallet, password: String, newPassword: String, newName: String) throws {
        guard let index = wallets.firstIndex(of: wallet) else { throw KeyStore.Error.accountNotFound }
        guard var privateKeyData = wallet.key.decryptPrivateKey(password: Data(password.utf8)) else { throw KeyStore.Error.invalidPassword }
        defer { privateKeyData.resetBytes(in: 0..<privateKeyData.count) }
        
        let coinDerivations = wallet.accounts.compactMap { $0.isDerived ? CoinDerivation(coin: $0.coin, derivation: $0.derivation) : nil }
        let initialCoin = coinDerivations.first?.coin ?? .ethereum
        
        if let mnemonic = checkMnemonic(privateKeyData),
           let key = StoredKey.importHDWallet(mnemonic: mnemonic, name: newName, password: Data(newPassword.utf8), coin: initialCoin) {
            wallets[index].key = key
        } else if let key = StoredKey.importPrivateKey(privateKey: privateKeyData, name: newName, password: Data(newPassword.utf8), coin: initialCoin) {
            wallets[index].key = key
        } else {
            throw KeyStore.Error.invalidKey
        }
        
        if coinDerivations.isEmpty {
            wallets[index].key.removeAccountForCoin(coin: initialCoin)
        } else {
            for coinDerivation in coinDerivations {
                try wallets[index].createAccount(password: newPassword, coin: coinDerivation.coin, derivation: coinDerivation.derivation)
            }
        }
        
        wallets[index].updateAccounts()
        try save(wallet: wallets[index], isUpdate: true)
    }

    private func save(wallet: TokenaryWallet, isUpdate: Bool) throws {
        guard let data = wallet.key.exportJSON() else { throw KeyStore.Error.invalidPassword }
        if isUpdate {
            try keychain.updateWallet(id: wallet.id, data: data)
        } else {
            try keychain.saveWallet(id: wallet.id, data: data)
        }
        postWalletsChangedNotification()
    }
    
    private func postWalletsChangedNotification() {
        NotificationCenter.default.post(name: Notification.Name.walletsChanged, object: nil)
    }
    
    private var defaultWalletName = ""
    
    private func makeNewWalletId() -> String {
        let uuid = UUID().uuidString
        let date = Date().timeIntervalSince1970
        let walletId = "\(uuid)-\(date)"
        return walletId
    }
    
}

extension WalletsManager {
    
    func getAccount(coin: CoinType, address: String) -> TokenaryAccount? {
        return getWalletAndAccount(coin: coin, address: address)?.1
    }
    
    func getPrivateKey(coin: CoinType, address: String) -> PrivateKey? {
        guard let password = Keychain.shared.password else { return nil }
        if let (wallet, account) = getWalletAndAccount(coin: coin, address: address) {
            return try? wallet.privateKey(password: password, account: account)
        } else {
            return nil
        }
    }
    
    func getWalletAndAccount(coin: CoinType, address: String) -> (TokenaryWallet, TokenaryAccount)? {
        let searchLowercase = coin == .ethereum
        let needle = searchLowercase ? address.lowercased() : address
        
        for wallet in wallets {
            for account in wallet.accounts where account.coin == coin {
                let match = searchLowercase ? account.address.lowercased() == needle : account.address == needle
                if match {
                    return (wallet, account)
                }
            }
        }
        
        return nil
    }
    
}
