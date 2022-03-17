// Copyright © 2021 Tokenary. All rights reserved.
// Rewrite of KeyStore.swift from Trust Wallet Core.

import Foundation
import WalletCore

final class WalletsManager {
    // MARK: - Types
    
    enum InputValidationResult: Equatable {
        public enum WalletKeyType: Equatable {
            case mnemonic
            case privateKey([SupportedChainType])
            
            var supportedChainTypes: [SupportedChainType] {
                switch self {
                case .mnemonic: return SupportedChainType.allCases
                case let .privateKey(supportedChainTypes): return supportedChainTypes
                }
            }
        }
        
        case valid(WalletKeyType)
        case passwordProtectedJSON
        case alreadyPresent
        case invalidData
        
        var walletKeyType: WalletKeyType? {
            if case let .valid(walletKeyType) = self {
                return walletKeyType
            } else {
                return nil
            }
        }
    }
    
    enum Error: Swift.Error {
        case keychainAccessFailure
        case invalidInput
    }
    
    static let shared = WalletsManager()
    private let keychain = Keychain.shared
    private(set) var wallets = [TokenaryWallet]()

    private init() {}

    func start() {
        try? load()
    }
    
    #if os(macOS)
    func migrateFromLegacyIfNeeded() {
        guard !Defaults.didMigrateKeychainFromTokenaryV1 else { return }
        let legacyKeystores = keychain.getLegacyKeystores()
        if !legacyKeystores.isEmpty, let legacyPassword = keychain.legacyPassword {
            keychain.save(password: legacyPassword)
            for keystore in legacyKeystores {
                _ = try? importJSON(keystore,
                                    name: self.getMnemonicDefaultWalletName(),
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
    
    private func importJSON(_ json: Data, name: String, password: String, newPassword: String, coin: CoinType, onlyToKeychain: Bool) throws -> TokenaryWallet {
        guard
            let key = StoredKey.importJSON(json: json)
        else { throw KeyStore.Error.invalidKey }
        guard
            let data = key.decryptPrivateKey(password: Data(password.utf8))
        else { throw KeyStore.Error.invalidPassword }
        if let mnemonic = checkMnemonic(data) {
            return try self.`import`(
                mnemonic: mnemonic, name: name, password: newPassword, coinTypes: [coin]
            )
        }
        guard let privateKey = PrivateKey(data: data) else { throw KeyStore.Error.invalidKey } // This method doesn't do shit
        return try self.`import`(
            privateKey: privateKey, name: name, password: newPassword, coinType: coin, onlyToKeychain: onlyToKeychain
        )
    }
    
    // MARK: - Validate
    
    func getValidationFor(input: String) -> InputValidationResult {
        func checkForEncryptedJSON() -> InputValidationResult {
            if false {
                // ToDo(@pettrk): Check for all present keys and mnemonics and return this if match found
                //                  This will require to run through all items though, maybe use another approach
                return .alreadyPresent
            }
            return input.maybeJSON ? .passwordProtectedJSON : .invalidData
        }
        if Mnemonic.isValid(mnemonic: input) {
            return .valid(.mnemonic)
        } else if let data = Data(hexString: input) {
            let possiblePrivateKeyDerivations: [SupportedChainType] = [.ethereum, .solana]
                .compactMap { PrivateKey.isValid(data: data, curve: $0.curve) ? $0 : nil }
            if possiblePrivateKeyDerivations.count != .zero {
                return .valid(.privateKey(possiblePrivateKeyDerivations))
            } else {
                return checkForEncryptedJSON()
            }
        } else { // This case needs more insights into
            return checkForEncryptedJSON()
        }
    }
    
    // ToDo(@pettrk): There is a problem with this function, since we don't handle the case for mnemonics
    //  https://github.com/ttmbank/wallet-core-first/blob/fffb7bd30e2d17e018cd1dd8c066014b159af487/tests/Keystore/Data/key.json
    // This should work, however for some reason it doesn't with current library version.
    func decryptJSONAndValidate(input: String, password: String) -> (InputValidationResult, String?) {
        if
            let json = input.data(using: .utf8),
            let key = StoredKey.importJSON(json: json),
            let data = key.decryptPrivateKey(password: Data(password.utf8)),
            let stringRepresentation = String(data: data, encoding: .ascii),
            let validRepresentation = self.getValidationFor(input: stringRepresentation).walletKeyType
        {
            if validRepresentation == .mnemonic {
                return (.valid(validRepresentation), stringRepresentation)
            } else {
                return (.valid(validRepresentation), data.hexString)
            }
        } else {
            return (.invalidData, nil)
        }
    }
    
    // MARK: - Create & Import
    
    func createMnemonicWallet(name: String? = nil, coinTypes: [CoinType]) throws -> TokenaryWallet {
        guard coinTypes.count != .zero else { throw Error.invalidInput }
        guard let password = keychain.password else { throw Error.keychainAccessFailure }
        let newKey = StoredKey(
            name: name ?? self.getMnemonicDefaultWalletName(),
            password: Data(password.utf8),
            // ToDo(@pettrk): Weak was used previously, however longer needs considerable time
            encryptionLevel: .standard
        )
        
        return try self.finaliseWalletCreation(
            key: newKey, coinTypes: coinTypes, isMnemonic: true, onlyToKeychain: false
        )
    }
    
    @discardableResult
    func addWallet(input: String, chainTypes: [SupportedChainType]) throws -> TokenaryWallet {
        guard let password = keychain.password else { throw Error.keychainAccessFailure }
        if Mnemonic.isValid(mnemonic: input) {
            return try `import`(
                mnemonic: input,
                name: self.getMnemonicDefaultWalletName(),
                password: password,
                coinTypes: chainTypes.map { $0.walletCoreCoinType }
            )
        } else if
            let data = Data(hexString: input),
            let privateKey = PrivateKey(data: data),
            let chain = chainTypes.first // always single element for private keys
        {
            return try `import`(
                privateKey: privateKey,
                name: self.getPrivateKeyDefaultWalletName(for: chain),
                password: password,
                coinType: chain.walletCoreCoinType,
                onlyToKeychain: false
            )
        } else {
            throw Error.invalidInput
        }
    }
    
    // MARK: - Import

    // importPrivateKey ->
    //  TWStoredKeyImportPrivateKey ->
    //  create StoredKey through createWithPrivateKeyAddDefaultAddress(wrapped in TWStoreField) ->
    //  check if curves are matching  ->
    //      it's often true, so it doesn't help(except when checking for nist256p1 or secp256k1)
    //  Create private key(simultaneously encrypting it)
    private func `import`(
        privateKey: PrivateKey, name: String, password: String, coinType: CoinType, onlyToKeychain: Bool
    ) throws -> TokenaryWallet {
        guard
            let newKey = StoredKey.importPrivateKey(
                privateKey: privateKey.data, name: name, password: Data(password.utf8), coin: coinType
            )
        else { throw KeyStore.Error.invalidKey }
        
        return try self.finaliseWalletCreation(
            key: newKey, coinTypes: [coinType], isMnemonic: false, onlyToKeychain: onlyToKeychain
        )
    }

    private func `import`(
        mnemonic: String, name: String, password: String, coinTypes: [CoinType] // ToDo(@pettrk): OptionSet?
    ) throws -> TokenaryWallet {
        let defaultCoinType = coinTypes.first ?? WalletsManager.defaultCoinType
        guard
            let newKey = StoredKey.importHDWallet(
                mnemonic: mnemonic, name: name, password: Data(password.utf8), coin: defaultCoinType
            )
        else { throw KeyStore.Error.invalidMnemonic }
        try self.addAccounts(key: newKey, password: password, coins: Array(coinTypes.dropFirst()))
        
        return try self.finaliseWalletCreation(
            key: newKey, coinTypes: coinTypes, isMnemonic: true, onlyToKeychain: false
        )
    }
    
    private func finaliseWalletCreation(
        key: StoredKey, coinTypes: [CoinType], isMnemonic: Bool, onlyToKeychain: Bool
    ) throws -> TokenaryWallet {
        guard let data = key.exportJSON() else { throw KeyStore.Error.invalidPassword }
        let id = makeNewWalletId()
        let derivedChains = coinTypes.compactMap { SupportedChainType(coinType: $0) }
        
        try keychain.saveWallet(
            id: id,
            data: data,
            metaData: Keychain.MetaData(
                derivedChains: derivedChains,
                keychainMigrationVersion: Constants.currentKeychainMigrationVersion,
                vaultIdentifier: nil
            )
        )
        
        let (createdAt, lastUpdatedAt, _) = keychain.getAssociatedWalletData(id: id) ?? (.now, .now, nil)
        
        let wallet = TokenaryWallet(
            id: id,
            key: key,
            associatedMetadata: .init(
                createdAt: createdAt,
                lastUpdatedAt: lastUpdatedAt ?? createdAt,
                walletDerivationType: isMnemonic ? .mnemonic(derivedChains) : .privateKey(derivedChains.first!),
                iconURL: nil,
                vaultIdentifier: nil
            )
        )
        
        if !onlyToKeychain {
            self.wallets.append(wallet)
        }
        self.postWalletsChangedNotification()
        return wallet
    }
    
    // MARK: - Update
                                   
    public func rename(wallet: TokenaryWallet, newName: String) throws {
        guard let password = keychain.password else { throw Error.keychainAccessFailure }
        try update(wallet: wallet, oldPassword: password, newPassword: password, newName: newName)
    }
    
    public func changeIconIn(wallet: TokenaryWallet, newIconURL: URL) {
        _unimplemented("This is not implemented yet!")
    }
    
    public func changeAccountsIn(wallet: TokenaryWallet, to newChainTypes: [SupportedChainType]) throws {
        guard wallet.isMnemonic else { return }
        guard let password = keychain.password else { throw Error.keychainAccessFailure }
        let currentAccounts = Set(wallet.associatedMetadata.walletDerivationType.chainTypes)
        let accountsToRemove = currentAccounts.subtracting(newChainTypes)
        let accountsToAdd = Set(newChainTypes).subtracting(currentAccounts)
        
        self.removeAccountFrom(wallet: wallet, for: Array(accountsToRemove))
        try self.addAccounts(key: wallet.key, password: password, coins: accountsToAdd.map { $0.walletCoreCoinType })
        wallet.associatedMetadata.walletDerivationType = .mnemonic(newChainTypes)
        try self.update(wallet: wallet)
    }
    
    public func removeAccountIn(wallet: TokenaryWallet, account: SupportedChainType) throws {
        guard wallet.isMnemonic else { return }
        self.removeAccountFrom(wallet: wallet, for: [account])
        let currentAccounts = wallet.associatedMetadata.walletDerivationType.chainTypes
        wallet.associatedMetadata.walletDerivationType = .mnemonic(currentAccounts.filter { $0 != account })
        try self.update(wallet: wallet)
    }
    
    public func update(wallet: TokenaryWallet) throws {
        guard let password = keychain.password else { throw Error.keychainAccessFailure }
        try update(wallet: wallet, oldPassword: password, newPassword: password, newName: wallet.key.name)
    }

    public func update(wallet: TokenaryWallet, oldPassword: String, newPassword: String) throws {
        try update(wallet: wallet, oldPassword: oldPassword, newPassword: newPassword, newName: wallet.key.name)
    }
    
    @discardableResult
    private func addAccount(
        key: StoredKey, password: String, coin: CoinType
    ) throws -> Account? {
        guard
            let wallet = key.wallet(password: Data(password.utf8))
        else { throw KeyStore.Error.invalidPassword }
        return key.accountForCoin(coin: coin, wallet: wallet)
    }
    
    @discardableResult
    private func addAccounts(
        key: StoredKey, password: String, coins: [CoinType]
    ) throws -> [Account] {
        guard
            let wallet = key.wallet(password: Data(password.utf8))
        else { throw KeyStore.Error.invalidPassword }
        return coins.compactMap { key.accountForCoin(coin: $0, wallet: wallet) }
    }
    
    private func removeAccountFrom(wallet: TokenaryWallet, for chainTypes: [SupportedChainType]) {
        for chainType in chainTypes {
            wallet.key.removeAccountForCoin(coin: chainType.walletCoreCoinType)
        }
    }
    
    private func update(wallet: TokenaryWallet, oldPassword: String, newPassword: String, newName: String) throws {
        guard
            let index = wallets.firstIndex(of: wallet)
        else { throw KeyStore.Error.accountNotFound }
        guard
            var privateKeyData = wallet.key.decryptPrivateKey(password: Data(oldPassword.utf8))
        else { throw KeyStore.Error.invalidPassword }
        defer { privateKeyData.resetBytes(in: .zero ..< privateKeyData.count) }
        let coins = wallet.associatedMetadata.walletDerivationType.chainTypes.map({ $0.walletCoreCoinType })
        guard !coins.isEmpty else { throw KeyStore.Error.accountNotFound }
        
        if
            let mnemonic = checkMnemonic(privateKeyData),
            let key = StoredKey.importHDWallet(
                mnemonic: mnemonic, name: newName, password: Data(newPassword.utf8), coin: coins[0]
            )
        {
            try self.addAccounts(key: key, password: newPassword, coins: Array(coins.dropFirst()))
            wallets[index].key = key
        } else if
            let key = StoredKey.importPrivateKey(
                privateKey: privateKeyData, name: newName, password: Data(newPassword.utf8), coin: coins[0]
            )
        {
            wallets[index].key = key
        } else {
            throw KeyStore.Error.invalidKey
        }
        
        guard let data = wallets[index].key.exportJSON() else { throw KeyStore.Error.invalidPassword }
        
        let walletId = wallets[index].id
        let derivedChains = coins.compactMap { SupportedChainType(coinType: $0) }
        
        try keychain.saveWallet(
            id: walletId,
            data: data,
            metaData: Keychain.MetaData(
                derivedChains: derivedChains,
                keychainMigrationVersion: Constants.currentKeychainMigrationVersion,
                vaultIdentifier: nil
            )
        )
        
        let (_, lastUpdatedAt, _) = keychain.getAssociatedWalletData(id: walletId) ?? (.now, .now, nil)
        wallets[index].associatedMetadata.lastUpdatedAt = lastUpdatedAt ?? .now
        
        self.postWalletsChangedNotification()
    }
    
    // MARK: - Get
    
    func getWallet(id: String) -> TokenaryWallet? {
        return wallets.first(where: { $0.id == id })
    }
    
    func getWallet(for chainType: SupportedChainType, havingAddress address: String) -> TokenaryWallet? {
        wallets.first(where: { wallet in
            if wallet.isMnemonic {
                for chain in wallet.associatedMetadata.walletDerivationType.chainTypes {
                    if let currentAddress = wallet[chain, .address] ?? nil {
                        if currentAddress.lowercased() == address.lowercased() {
                            return true
                        }
                    }
                }
            } else {
                if let currentAddress = wallet[.address] ?? nil {
                    if currentAddress.lowercased() == address.lowercased() {
                        return true
                    }
                }
            }
            return false
        })
    }
    
    // MARK: Store & Destroy
    
    private func load() throws {
        let ids = keychain.getAllWalletsIds().take(atMost: 2)
        var walletsToMigrate: [TokenaryWallet] = []
        for id in ids {
            guard
                let data = keychain.getWalletData(id: id),
                let key = StoredKey.importJSON(json: data),
                let (createdAt, lastUpdatedAt, metaData) = keychain.getAssociatedWalletData(id: id)
            else { continue }
            
            let walletDerivationType: TokenaryWallet.AssociatedMetadata.WalletDerivationType = key.isMnemonic
                ? .mnemonic(metaData?.derivedChains ?? [WalletsManager.defaultSupportedChainType])
                : .privateKey(metaData?.derivedChains.first ?? WalletsManager.defaultSupportedChainType)
            let wallet = TokenaryWallet(
                id: id,
                key: key,
                associatedMetadata: .init(
                    createdAt: createdAt,
                    lastUpdatedAt: lastUpdatedAt ?? createdAt,
                    walletDerivationType: walletDerivationType,
                    iconURL: nil,
                    vaultIdentifier: nil
                )
            )
            if wallet.name.count == .zero || wallet.name.trimmingCharacters(in: .whitespacesAndNewlines) == .empty {
                walletsToMigrate.append(wallet)
            }
            // ToDo(@pettrk) -> This should be an async wrapper, with stream semantics
            //  When size iz 50+ this works like a minute
            wallets.append(wallet)
        }
        
        for wallet in walletsToMigrate {
            try self.rename(wallet: wallet, newName: self.getMnemonicDefaultWalletName())
        }
    }
    
    func delete(wallet: TokenaryWallet) throws {
        guard let password = keychain.password else { throw Error.keychainAccessFailure }
        guard let index = wallets.firstIndex(of: wallet) else { throw KeyStore.Error.accountNotFound }
        guard
            var privateKey = wallet.key.decryptPrivateKey(password: Data(password.utf8))
        else { throw KeyStore.Error.invalidKey }
        defer { privateKey.resetBytes(in: 0 ..< privateKey.count) }
        wallets.remove(at: index)
        try keychain.removeWallet(id: wallet.id)
        postWalletsChangedNotification()
    }
    
    func destroy() throws {
        wallets.removeAll(keepingCapacity: false)
        try keychain.removeAllWallets()
        self.postWalletsChangedNotification()
    }
    
    // MARK: - Helper
    
    private func postWalletsChangedNotification() {
        NotificationCenter.default.post(name: Notification.Name.walletsChanged, object: nil)
    }
    
    private func makeNewWalletId() -> String {
        let uuid = UUID().uuidString
        let date = Date().timeIntervalSince1970
        let walletId = "\(uuid)-\(date)"
        return walletId
    }
    
    private func getMnemonicDefaultWalletName() -> String {
        "Wallet " + String.getRandomEmoticonsCollection(ofSize: 1).joined(separator: .empty)
    }
    
    private func getPrivateKeyDefaultWalletName(for chainType: SupportedChainType) -> String {
        defer { Defaults[.numberOfCreatedWallets(chainType)] += 1 }
        let numberOfCreatedWallets = Defaults[.numberOfCreatedWallets(chainType)]
        let walletNumber = numberOfCreatedWallets == .zero ? .empty : String(numberOfCreatedWallets) + Symbols.space
        return "\(chainType.title) Wallet \(walletNumber)(\(chainType.ticker))"
    }
    
    private func checkMnemonic(_ data: Data) -> String? {
        guard
            let mnemonic = String(data: data, encoding: .ascii),
                Mnemonic.isValid(mnemonic: mnemonic)
        else { return nil }
        return mnemonic
    }
    
    private static var defaultCoinType: CoinType = .ethereum
    private static var defaultSupportedChainType: SupportedChainType = .init(coinType: WalletsManager.defaultCoinType)!
}
