// Copyright © 2021 Tokenary. All rights reserved.
// Rewrite of KeyStore.swift from Trust Wallet Core.

import Foundation
import WalletCore

/// ToDo: This belongs to Tokenary Shared
final class WalletsManager {
    // MARK: - Types
    
    struct TokenaryWalletChangeSet {
        var toAdd: [TokenaryWallet]
        var toUpdate: [TokenaryWallet]
        var toRemove: [TokenaryWallet]
        
        mutating func applyFilter(_ filter: ([TokenaryWallet]) -> [TokenaryWallet]) {
            toAdd = filter(toAdd)
            toUpdate = filter(toUpdate)
            toRemove = filter(toRemove)
        }
    }
    
    enum InputValidationResult: Equatable {
        public enum WalletKeyType: Equatable {
            case mnemonic
            case privateKey([ChainType])
            
            var supportedChainTypes: [ChainType] {
                switch self {
                case .mnemonic:
                    return ChainType.supportedChains
                case let .privateKey(supportedChainTypes):
                    return supportedChainTypes
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
    private(set) var wallets = SynchronizedArray<TokenaryWallet>()

    private init() {}

    func start() {
        load()
    }
    
    #if os(macOS)
    func migrateFromLegacyIfNeeded() {
        guard !Defaults.didMigrateKeychainFromTokenaryV1 else { return }
        let legacyKeystores = keychain.getLegacyKeystores()
        if !legacyKeystores.isEmpty, let legacyPassword = keychain.legacyPassword {
            keychain.save(password: legacyPassword)
            for keystore in legacyKeystores {
                _ = try? importJSON(keystore,
                                    name: getMnemonicDefaultWalletName(),
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
    
    private func importJSON(_ json: Data, name: String, password: String, newPassword: String, chainType: ChainType, onlyToKeychain: Bool) throws -> TokenaryWallet {
        guard
            let key = StoredKey.importJSON(json: json)
        else { throw KeyStore.Error.invalidKey }
        guard
            let data = key.decryptPrivateKey(password: Data(password.utf8))
        else { throw KeyStore.Error.invalidPassword }
        if let mnemonic = checkMnemonic(data) {
            return try `import`(
                mnemonic: mnemonic, name: name, password: newPassword, chainTypes: [chainType]
            )
        }
        guard
            let privateKey = PrivateKey(data: data) // This method doesn't do shit
        else { throw KeyStore.Error.invalidKey }
        return try `import`(
            privateKey: privateKey, name: name, password: newPassword, chainType: chainType, onlyToKeychain: onlyToKeychain
        )
    }
    
    // MARK: - Validate
    
    func getValidationFor(input: String) -> InputValidationResult {
        func checkForEncryptedJSON() -> InputValidationResult {
            if false {
                // ToDo: Check for all present keys and mnemonics and return this if match found
                //                  This will require to run through all items though, maybe use another approach
                return .alreadyPresent
            }
            return input.maybeJSON ? .passwordProtectedJSON : .invalidData
        }
        if Mnemonic.isValid(mnemonic: input) {
            return .valid(.mnemonic)
        } else if let data = Data(hexString: input) {
            let possiblePrivateKeyDerivations: [ChainType] = [.ethereum, .solana]
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
    
    // ToDo: There is a problem with this function, since we don't handle the case for mnemonics
    //  https://github.com/ttmbank/wallet-core-first/blob/fffb7bd30e2d17e018cd1dd8c066014b159af487/tests/Keystore/Data/key.json
    // This should work, however for some reason it doesn't with current library version.
    func decryptJSONAndValidate(input: String, password: String) -> (InputValidationResult, String?) {
        if
            let json = input.data(using: .utf8),
            let key = StoredKey.importJSON(json: json),
            let data = key.decryptPrivateKey(password: Data(password.utf8)),
            let stringRepresentation = String(data: data, encoding: .ascii),
            let validRepresentation = getValidationFor(input: stringRepresentation).walletKeyType
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
    
    func createMnemonicWallet(name: String? = nil, chainTypes: [ChainType]) throws -> TokenaryWallet {
        guard chainTypes.count != .zero else { throw Error.invalidInput }
        guard let password = keychain.password else { throw Error.keychainAccessFailure }
        let newKey = StoredKey(
            name: name ?? getMnemonicDefaultWalletName(),
            password: Data(password.utf8)
        )
        try addAccounts(key: newKey, password: password, chainTypes: chainTypes)
        
        return try finaliseWalletCreation(
            key: newKey, chainTypes: chainTypes, isMnemonic: true, onlyToKeychain: false
        )
    }
    
    @discardableResult
    func addWallet(input: String, chainTypes: [ChainType]) throws -> TokenaryWallet {
        guard let password = keychain.password else { throw Error.keychainAccessFailure }
        if Mnemonic.isValid(mnemonic: input) {
            return try `import`(
                mnemonic: input,
                name: getMnemonicDefaultWalletName(),
                password: password,
                chainTypes: chainTypes
            )
        } else if
            let data = Data(hexString: input),
            let privateKey = PrivateKey(data: data),
            let chain = chainTypes.first // always single element for private keys
        {
            return try `import`(
                privateKey: privateKey,
                name: getPrivateKeyDefaultWalletName(for: chain),
                password: password,
                chainType: chain,
                onlyToKeychain: false
            )
        } else {
            throw Error.invalidInput
        }
    }
    
    // MARK: - Import

    private func `import`(
        privateKey: PrivateKey, name: String, password: String, chainType: ChainType, onlyToKeychain: Bool
    ) throws -> TokenaryWallet {
        guard
            let newKey = StoredKey.importPrivateKey(
                privateKey: privateKey.data, name: name, password: Data(password.utf8), coin: chainType
            )
        else { throw KeyStore.Error.invalidKey }
        
        return try finaliseWalletCreation(
            key: newKey, chainTypes: [chainType], isMnemonic: false, onlyToKeychain: onlyToKeychain
        )
    }

    private func `import`(
        mnemonic: String, name: String, password: String, chainTypes: [ChainType]
    ) throws -> TokenaryWallet {
        let defaultChainType = chainTypes.first ?? WalletsManager.defaultChainType
        guard
            let newKey = StoredKey.importHDWallet(
                mnemonic: mnemonic, name: name, password: Data(password.utf8), coin: defaultChainType
            )
        else { throw KeyStore.Error.invalidMnemonic }
        try addAccounts(key: newKey, password: password, chainTypes: Array(chainTypes.dropFirst()))
        
        return try finaliseWalletCreation(
            key: newKey, chainTypes: chainTypes, isMnemonic: true, onlyToKeychain: false
        )
    }
    
    private func finaliseWalletCreation(
        key: StoredKey, chainTypes: [ChainType], isMnemonic: Bool, onlyToKeychain: Bool
    ) throws -> TokenaryWallet {
        guard let data = key.exportJSON() else { throw KeyStore.Error.invalidPassword }
        let id = makeNewWalletId()
        
        try keychain.saveWallet(id: id, data: data)
        
        let wallet = TokenaryWallet(
            id: id, key: key, associatedMetadata: .init(key: key)
        )
        
        if !onlyToKeychain {
            wallets.append(wallet)
        }
        postWalletsChangedNotification(toAdd: [wallet])
        return wallet
    }
    
    // MARK: - Update
                                   
    public func rename(wallet: TokenaryWallet, newName: String) throws {
        guard let password = keychain.password else { throw Error.keychainAccessFailure }
        try update(wallet: wallet, oldPassword: password, newPassword: password, newName: newName)
    }
    
    public func changeAccountsIn(wallet: TokenaryWallet, to newChainTypes: [ChainType]) throws {
        guard wallet.isMnemonic else { return }
        guard let password = keychain.password else { throw Error.keychainAccessFailure }
        let currentAccounts = Set(wallet.associatedMetadata.allChains)
        let accountsToRemove = currentAccounts.subtracting(newChainTypes)
        let accountsToAdd = Set(newChainTypes).subtracting(currentAccounts)
        
        removeAccountFrom(wallet: wallet, for: accountsToRemove)
        try addAccounts(key: wallet.key, password: password, chainTypes: Array(accountsToAdd))
        wallet.refreshAssociatedData()
        try update(wallet: wallet)
    }
    
    public func removeAccountIn(wallet: TokenaryWallet, account: ChainType) throws {
        guard wallet.isMnemonic else { return }
        removeAccountFrom(wallet: wallet, for: [account])
        wallet.refreshAssociatedData()
        try update(wallet: wallet)
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
        key: StoredKey, password: String, chainType: ChainType
    ) throws -> Account? {
        guard
            let wallet = key.wallet(password: Data(password.utf8))
        else { throw KeyStore.Error.invalidPassword }
        return key.accountForCoin(coin: chainType, wallet: wallet)
    }
    
    @discardableResult
    private func addAccounts(
        key: StoredKey, password: String, chainTypes: [ChainType]
    ) throws -> [Account] {
        guard
            let wallet = key.wallet(password: Data(password.utf8))
        else { throw KeyStore.Error.invalidPassword }
        return chainTypes.compactMap { key.accountForCoin(coin: $0, wallet: wallet) }
    }
    
    private func removeAccountFrom(wallet: TokenaryWallet, for chainTypes: Set<ChainType>) {
        for chainType in chainTypes {
            wallet.key.removeAccountForCoin(coin: chainType)
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
        let coins = wallet.associatedMetadata.allChains
        guard !coins.isEmpty else { throw KeyStore.Error.accountNotFound }
        
        if
            let mnemonic = checkMnemonic(privateKeyData),
            let key = StoredKey.importHDWallet(
                mnemonic: mnemonic, name: newName, password: Data(newPassword.utf8), coin: coins[0]
            )
        {
            try addAccounts(key: key, password: newPassword, chainTypes: Array(coins.dropFirst()))
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
        
        try keychain.saveWallet(id: wallets[index].id, data: data)
        
        postWalletsChangedNotification(toUpdate: [wallet])
    }
    
    // MARK: - Get
    
    func getWallet(id: String) -> TokenaryWallet? {
        return wallets.first(where: { $0.id == id })
    }
    
    func getWallet(for chainType: ChainType, havingAddress address: String) -> TokenaryWallet? {
        wallets.first(where: { wallet in
            if wallet.isMnemonic {
                for chain in wallet.associatedMetadata.allChains {
                    if let currentAddress = wallet[chain, .address] ?? nil {
                        if currentAddress.lowercased() == address.lowercased() {
                            return true
                        }
                    }
                }
            } else {
                if
                    wallet.associatedMetadata.privateKeyChain == chainType,
                    let currentAddress = wallet[.address] ?? nil
                {
                    if currentAddress.lowercased() == address.lowercased() {
                        return true
                    }
                }
            }
            return false
        })
    }
    
    // MARK: Store & Destroy
    
    private let operationQueue = DispatchQueue(label: "io.tokenary.WalletManager", qos: .userInitiated)
    
    private func load() {
        operationQueue.async {
            let ids = self.keychain.getAllWalletsIds()
            var walletsToMigrate: [TokenaryWallet] = []
            
            for id in ids {
                guard
                    let data = self.keychain.getWalletData(id: id),
                    let key = StoredKey.importJSON(json: data)
                else { continue }
                
                let wallet = TokenaryWallet(
                    id: id,
                    key: key,
                    associatedMetadata: .init(key: key)
                )
                
                if wallet.name.count == .zero || wallet.name.trimmingCharacters(in: .whitespacesAndNewlines) == .empty {
                    walletsToMigrate.append(wallet)
                }
                
                self.wallets.append(wallet)
            }
            
            DispatchQueue.main.async {
                self.postWalletsChangedNotification(toAdd: self.wallets.get())
            }
            
            for wallet in walletsToMigrate {
                try? self.rename(wallet: wallet, newName: self.getMnemonicDefaultWalletName())
            }
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
        postWalletsChangedNotification(toRemove: [wallet])
    }
    
    func destroy() throws {
        wallets.removeAll(keepingCapacity: false)
        try keychain.removeAllWallets()
        postWalletsChangedNotification(toRemove: wallets.get())
    }
    
    // MARK: - Helper
    
    private func postWalletsChangedNotification(
        toAdd: [TokenaryWallet] = [], toUpdate: [TokenaryWallet] = [], toRemove: [TokenaryWallet] = []
    ) {
        NotificationCenter.default.post(
            name: Notification.Name.walletsChanged,
            object: nil,
            userInfo: [
                "changeset":
                    TokenaryWalletChangeSet(
                        toAdd: toAdd,
                        toUpdate: toUpdate,
                        toRemove: toRemove
                    )
            ]
        )
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
    
    private func getPrivateKeyDefaultWalletName(for chainType: ChainType) -> String {
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
    
    private static var defaultChainType: ChainType = .ethereum
}
