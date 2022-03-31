// Copyright © 2021 Tokenary. All rights reserved.
// Rewrite of Wallet.swift from Trust Wallet Core.

import Foundation
import WalletCore

/// ToDo: This belongs to Tokenary Shared
protocol AnyAccount {
    var chainType: ChainType { get }
    
    var privateKey: PrivateKey? { get }
    var address: String? { get }
    var privateKeyString: String? { get }
    var derivationPath: String? { get }
}

public final class TokenaryWallet: Hashable, Equatable {
    public struct AccountDescriptor<ReturnType> {
        var keyPath: KeyPath<AnyAccount, ReturnType>
    }
    
    /// Used so we cache `StoredKey.account(index:_)` calls
    public struct AssociatedMetadata {
        private var indexToChainMap: [ChainType] = []
        private var chainToIndexMap: [ChainType: Int] = [:]
        
        func indexFor(chain: ChainType) -> Int? { chainToIndexMap[chain] }
        
        func chainFor(index: Int) -> ChainType? { indexToChainMap[index] }
        
        public var privateKeyChain: ChainType? { indexToChainMap[.zero] }
        
        public var allChains: [ChainType] { Array(chainToIndexMap.keys) }
        
        internal init(key: StoredKey) {
            for index in .zero ..< key.accountCount {
                guard let accountChain = key.account(index: index)?.coin else { return }
                indexToChainMap.append(accountChain)
                chainToIndexMap[accountChain] = index
            }
        }
    }
    
    struct DerivedMnemonicAccount: AnyAccount {
        init?(key: StoredKey, chainType: ChainType, address: String?) {
            self.key = key
            self.chainType = chainType
            self.address = address
        }
        
        var key: StoredKey
        var chainType: ChainType
        
        var privateKey: PrivateKey? {
            guard
                let password = Keychain.shared.password,
                let privateKey = key.privateKey(
                    coin: chainType, password: Data(password.utf8)
                )
            else { return nil }
            return privateKey
        }
        
        let address: String?
        
        // ToDo: Applying formatter
        var privateKeyString: String? { privateKey?.data.hexString }
        
        var derivationPath: String? {
            guard
                let password = Keychain.shared.password,
                let wallet = key.wallet(password: Data(password.utf8)),
                let account = key.accountForCoin(coin: chainType, wallet: wallet)
            else { return nil  }
            return account.derivationPath
        }
    }
    
    struct PrivateKeyDerivedAccount: AnyAccount {
        internal init(key: StoredKey, chainType: ChainType, address: String?) {
            self.key = key
            self.chainType = chainType
            self.address = address
        }
        
        var key: StoredKey
        var chainType: ChainType
        
        var privateKey: PrivateKey? {
            guard
                let password = Keychain.shared.password,
                let privateKey = key.decryptPrivateKey(password: Data(password.utf8))
            else { return nil }
            return PrivateKey(data: privateKey)
        }
        
        let address: String?
        
        var privateKeyString: String? {
            privateKey?.data.hexString
        }
        
        var derivationPath: String? {
            key.accountForCoin(coin: chainType, wallet: nil)?.address
        }
    }

    let id: String
    var key: StoredKey {
        didSet {
            associatedMetadata = AssociatedMetadata(key: key)
        }
    }
    private(set) var associatedMetadata: AssociatedMetadata {
        didSet {
            accounts = generateAccounts()
        }
    }
    
    private lazy var accounts: [AnyAccount] = self.generateAccounts()
    
    var isMnemonic: Bool { key.isMnemonic }
    
    var name: String { key.name }
    
    var mnemonic: String {
        // swiftlint:disable implicit_getter
        get throws {
            guard
                let password = Keychain.shared.password
            else { throw WalletsManager.Error.keychainAccessFailure }
            guard
                let mnemonic = key.decryptMnemonic(password: Data(password.utf8))
            else { throw KeyStore.Error.invalidPassword }
            return mnemonic
        }
        // swiftlint:enable implicit_getter
    }
    
    init(id: String, key: StoredKey, associatedMetadata: AssociatedMetadata) {
        self.id = id
        self.key = key
        self.associatedMetadata = associatedMetadata
    }
     
    public subscript<T>(chainType: ChainType, accountDescriptor: AccountDescriptor<T>) -> T? {
        // No throwing keypath available. Nil is sufficient here
        guard
            isMnemonic,
            let account = accounts.first(where: { $0.chainType == chainType })
        else { return nil }
        return account[keyPath: accountDescriptor.keyPath]
    }
    
    public subscript<T>(accountDescriptor: AccountDescriptor<T>) -> T? {
        // Usage requires that you manually check, either provided descriptor actually matches
        guard
            !isMnemonic,
            let account = accounts.first
        else { return nil }
        return account[keyPath: accountDescriptor.keyPath]
    }

    public func hash(into hasher: inout Hasher) { hasher.combine(id) }

    public static func == (lhs: TokenaryWallet, rhs: TokenaryWallet) -> Bool { lhs.id == rhs.id }
    
    public func refreshAssociatedData() {
        associatedMetadata = AssociatedMetadata(key: key)
    }
    
    private func generateAccounts() -> [AnyAccount] {
        (.zero ..< key.accountCount)
            .compactMap { key.account(index: $0) }
            .compactMap {
                if isMnemonic {
                    return DerivedMnemonicAccount(key: key, chainType: $0.coin, address: $0.address)
                } else {
                    return PrivateKeyDerivedAccount(key: key, chainType: $0.coin, address: $0.address)
                }
            }
    }
}

extension TokenaryWallet.AccountDescriptor {
    static var privateKey: TokenaryWallet.AccountDescriptor<PrivateKey?> {
        .init(keyPath: \.privateKey)
    }
    
    static var address: TokenaryWallet.AccountDescriptor<String?> {
        .init(keyPath: \.address)
    }
    
    static var privateKeyString: TokenaryWallet.AccountDescriptor<String?> {
        .init(keyPath: \.privateKeyString)
    }
    
    static var derivationPath: TokenaryWallet.AccountDescriptor<String?> {
        .init(keyPath: \.derivationPath)
    }
}
