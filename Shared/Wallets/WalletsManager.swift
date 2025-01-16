// ∅ 2025 lil org
// Rewrite of KeyStore.swift from Trust Wallet Core.

import Foundation
import WalletCore

final class WalletsManager {

    enum Error: Swift.Error {
        case keychainAccessFailure
        case invalidInput
        case failedToDeriveAccount
    }
    
    enum InputValidationResult {
        case valid, invalid, requiresPassword
    }
    
    static let shared = WalletsManager()
    private let keychain = Keychain.shared
    private let defaultCoin = CoinType.ethereum
    private(set) var wallets = [WalletContainer]()

    private init() {}

    func start() {
        try? loadWalletsFromKeychain()
    }
    
    func validateWalletInput(_ input: String) -> InputValidationResult {
        let trimmedInput = input.singleSpaced
        if Mnemonic.isValid(mnemonic: trimmedInput) {
            return .valid
        } else if let data = Data(hexString: trimmedInput) {
            return PrivateKey.isValid(data: data, curve: defaultCoin.curve) ? .valid : .invalid
        } else {
            return input.maybeJSON ? .requiresPassword : .invalid
        }
    }
    
    func createWallet() throws -> WalletContainer {
        guard let password = keychain.password else { throw Error.keychainAccessFailure }
        return try createWallet(name: defaultWalletName, password: password)
    }
    
    func getWallet(id: String) -> WalletContainer? {
        return wallets.first(where: { $0.id == id })
    }
    
    func addWallet(input: String, inputPassword: String?) throws -> WalletContainer {
        guard let password = keychain.password else { throw Error.keychainAccessFailure }
        let name = defaultWalletName
        let trimmedInput = input.singleSpaced
        if Mnemonic.isValid(mnemonic: trimmedInput) {
            return try importMnemonic(trimmedInput, name: name, encryptPassword: password)
        } else if let data = Data(hexString: trimmedInput), PrivateKey.isValid(data: data, curve: defaultCoin.curve), let privateKey = PrivateKey(data: data) {
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
    
    func suggestedAccounts(coin: CoinType? = nil) -> [SpecificWalletAccount] {
        let coinToSelect = coin ?? defaultCoin
        for wallet in wallets {
            if let account = wallet.accounts.first(where: { $0.coin == coinToSelect }) {
                return [SpecificWalletAccount(walletId: wallet.id, account: account)]
            }
        }
        return []
    }
    
    func previewAccounts(wallet: WalletContainer, page: Int) throws -> [Account] {
        guard let password = keychain.password, let hdWallet = wallet.key.wallet(password: Data(password.utf8)) else { throw Error.keychainAccessFailure }
        let coin = defaultCoin
        let range = (page * 21)..<((page + 1) * 21)
        let accounts = range.compactMap { i -> Account? in
            let dp = DerivationPath(purpose: .bip44, coin: coin.slip44Id, account: 0, change: 0, address: UInt32(i)).description
            let xpub = hdWallet.getExtendedPublicKey(purpose: coin.purpose, coin: coin, version: .xpub)
            guard let pubkey = HDWallet.getPublicKeyFromExtended(extended: xpub, coin: coin, derivationPath: dp) else { return nil }
            let address = coin.deriveAddressFromPublicKey(publicKey: pubkey)
            let account = Account(address: address, coin: coin, derivation: .custom, derivationPath: dp, publicKey: pubkey.description, extendedPublicKey: xpub)
            return account
        }
        guard accounts.count == range.count else { throw Error.failedToDeriveAccount }
        return accounts
    }
    
    private func createWallet(name: String, password: String) throws -> WalletContainer {
        let key = StoredKey(name: name, password: Data(password.utf8))
        let id = makeNewWalletId()
        let wallet = WalletContainer(id: id, key: key)
        _ = try wallet.getAccount(password: password, coin: defaultCoin)
        wallets.append(wallet)
        try save(wallet: wallet, isUpdate: false)
        return wallet
    }

    private func importJSON(_ json: Data, name: String, password: String, newPassword: String, coin: CoinType, onlyToKeychain: Bool) throws -> WalletContainer {
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

    private func importPrivateKey(_ privateKey: PrivateKey, name: String, password: String, coin: CoinType, onlyToKeychain: Bool) throws -> WalletContainer {
        guard let newKey = StoredKey.importPrivateKey(privateKey: privateKey.data, name: name, password: Data(password.utf8), coin: coin) else { throw KeyStore.Error.invalidKey }
        let id = makeNewWalletId()
        let wallet = WalletContainer(id: id, key: newKey)
        _ = try wallet.getAccount(password: password, coin: coin)
        if !onlyToKeychain {
            wallets.append(wallet)
        }
        try save(wallet: wallet, isUpdate: false)
        return wallet
    }

    private func importMnemonic(_ mnemonic: String, name: String, encryptPassword: String) throws -> WalletContainer {
        guard let key = StoredKey.importHDWallet(mnemonic: mnemonic, name: name, password: Data(encryptPassword.utf8), coin: defaultCoin) else { throw KeyStore.Error.invalidMnemonic }
        let id = makeNewWalletId()
        let wallet = WalletContainer(id: id, key: key)
        _ = try wallet.getAccount(password: encryptPassword, coin: defaultCoin)
        wallets.append(wallet)
        try save(wallet: wallet, isUpdate: false)
        return wallet
    }

    func exportPrivateKey(wallet: WalletContainer) throws -> Data {
        guard let password = keychain.password else { throw Error.keychainAccessFailure }
        guard let key = wallet.key.decryptPrivateKey(password: Data(password.utf8)) else { throw KeyStore.Error.invalidPassword }
        return key
    }

    func exportMnemonic(wallet: WalletContainer) throws -> String {
        guard let password = keychain.password else { throw Error.keychainAccessFailure }
        guard let mnemonic = wallet.key.decryptMnemonic(password: Data(password.utf8)) else { throw KeyStore.Error.invalidPassword }
        return mnemonic
    }

    func update(wallet: WalletContainer, newPassword: String) throws {
        guard let password = keychain.password else { throw Error.keychainAccessFailure }
        try update(wallet: wallet, password: password, newPassword: newPassword, newName: wallet.key.name)
    }

    func delete(wallet: WalletContainer) throws {
        guard let password = keychain.password else { throw Error.keychainAccessFailure }
        guard let index = wallets.firstIndex(of: wallet) else { throw KeyStore.Error.accountNotFound }
        guard var privateKey = wallet.key.decryptPrivateKey(password: Data(password.utf8)) else { throw KeyStore.Error.invalidKey }
        defer { privateKey.resetBytes(in: 0..<privateKey.count) }
        wallets.remove(at: index)
        try keychain.removeWallet(id: wallet.id)
        postWalletsChangedNotification()
    }

    func destroy() throws {
        wallets.removeAll(keepingCapacity: false)
        try keychain.removeAllWallets()
    }
    
    private func loadWalletsFromKeychain() throws {
        let ids = keychain.getAllWalletsIds()
        for id in ids {
            guard let data = keychain.getWalletData(id: id), let key = StoredKey.importJSON(json: data) else { continue }
            let wallet = WalletContainer(id: id, key: key)
            wallets.append(wallet)
        }
    }
    
    func update(wallet: WalletContainer, enabledAccounts: [Account]) throws {
        for account in wallet.accounts {
            wallet.key.removeAccountForCoinDerivationPath(coin: account.coin, derivationPath: account.derivationPath)
        }
        for account in enabledAccounts {
            wallet.key.addAccountDerivation(address: account.address,
                                            coin: account.coin,
                                            derivation: account.derivation,
                                            derivationPath: account.derivationPath,
                                            publicKey: account.publicKey,
                                            extendedPublicKey: account.extendedPublicKey)
        }
        try save(wallet: wallet, isUpdate: true)
    }
    
    func update(wallet: WalletContainer, removeAccounts toRemove: [Account]) throws {
        for account in toRemove {
            wallet.key.removeAccountForCoinDerivationPath(coin: account.coin, derivationPath: account.derivationPath)
        }
        
        try save(wallet: wallet, isUpdate: true)
    }
    
    private func update(wallet: WalletContainer, password: String, newPassword: String, newName: String) throws {
        guard let index = wallets.firstIndex(of: wallet) else { throw KeyStore.Error.accountNotFound }
        guard var privateKeyData = wallet.key.decryptPrivateKey(password: Data(password.utf8)) else { throw KeyStore.Error.invalidPassword }
        defer { privateKeyData.resetBytes(in: 0..<privateKeyData.count) }
        let enabledAccounts = wallet.accounts
        
        if let mnemonic = checkMnemonic(privateKeyData),
           let key = StoredKey.importHDWallet(mnemonic: mnemonic, name: newName, password: Data(newPassword.utf8), coin: defaultCoin) {
            wallets[index].key = key
        } else if let key = StoredKey.importPrivateKey(privateKey: privateKeyData, name: newName, password: Data(newPassword.utf8), coin: defaultCoin) {
            wallets[index].key = key
        } else {
            throw KeyStore.Error.invalidKey
        }
        
        wallets[index].key.removeAccountForCoin(coin: defaultCoin)
        for account in enabledAccounts {
            wallets[index].key.addAccountDerivation(address: account.address,
                                                    coin: account.coin,
                                                    derivation: account.derivation,
                                                    derivationPath: account.derivationPath,
                                                    publicKey: account.publicKey,
                                                    extendedPublicKey: account.extendedPublicKey)
        }
        
        try save(wallet: wallets[index], isUpdate: true)
    }

    private func save(wallet: WalletContainer, isUpdate: Bool) throws {
        guard let data = wallet.key.exportJSON() else { throw KeyStore.Error.invalidPassword }
        if isUpdate {
            try keychain.updateWallet(id: wallet.id, data: data)
        } else {
            try keychain.saveWallet(id: wallet.id, data: data)
        }
        postWalletsChangedNotification()
    }
    
    private func postWalletsChangedNotification() {
        NotificationCenter.default.post(name: .walletsChanged, object: nil)
    }
    
    private let defaultWalletName = ""
    
    private func makeNewWalletId() -> String {
        let uuid = UUID().uuidString
        let date = Date().timeIntervalSince1970
        let walletId = "\(uuid)-\(date)"
        return walletId
    }
    
}

extension WalletsManager {
    
    func getAccount(coin: CoinType, address: String) -> Account? {
        return getWalletAndAccount(coin: coin, address: address)?.1
    }
    
    func getPrivateKey(wallet: WalletContainer, account: Account) -> PrivateKey? {
        guard let password = Keychain.shared.password else { return nil }
        return try? wallet.privateKey(password: password, account: account)
    }
    
    func getPrivateKey(coin: CoinType, address: String) -> PrivateKey? {
        guard let password = Keychain.shared.password else { return nil }
        if let (wallet, account) = getWalletAndAccount(coin: coin, address: address) {
            return try? wallet.privateKey(password: password, account: account)
        } else {
            return nil
        }
    }
    
    func getWalletAndAccount(coin: CoinType, address: String) -> (WalletContainer, Account)? {
        let needle = address.lowercased()
        for wallet in wallets {
            for account in wallet.accounts where account.coin == coin {
                let match = account.address.lowercased() == needle
                if match {
                    return (wallet, account)
                }
            }
        }
        return nil
    }
    
}
