// Copyright © 2021 Tokenary. All rights reserved.
// Rewrite of Wallet.swift from Trust Wallet Core.

import Foundation
import WalletCore
import ComposableArchitecture

protocol AnyAccount {
    var chainType: SupportedChainType { get }
    
    var privateKey: PrivateKey? { get }
    var address: String? { get }
    var privateKeyString: String? { get }
    var derivationPath: String? { get }
}

final class TokenaryWallet: Hashable, Equatable {
    
    public struct AssociatedMetadata {
        public enum WalletDerivationType {
            case mnemonic([SupportedChainType])
            case privateKey(SupportedChainType)
            
            var chainTypes: [SupportedChainType] {
                switch self {
                case let .mnemonic(supportedChains):
                    return supportedChains
                case let .privateKey(supportedChain):
                    return [supportedChain]
                }
            }
        }
        
        internal init(
            createdAt: Date,
            lastUpdatedAt: Date,
            walletDerivationType: WalletDerivationType,
            iconURL: URL?,
            vaultIdentifier: String?
        ) {
            self.createdAt = createdAt
            self.lastUpdatedAt = lastUpdatedAt
            self.walletDerivationType = walletDerivationType
            self.iconURL = iconURL
            self.vaultIdentifier = vaultIdentifier
        }
        
        public let createdAt: Date
        public var lastUpdatedAt: Date
        public let walletDerivationType: WalletDerivationType
        public let iconURL: URL?
        
        private let vaultIdentifier: String?
    }

    let id: String
    var key: StoredKey
    var associatedMetadata: AssociatedMetadata
    
    private lazy var accounts: [AnyAccount] = {
        associatedMetadata.walletDerivationType.chainTypes.map {
            if self.isMnemonic {
                return DerivedMnemonicAccount(key: key, chainType: $0)
            } else {
                return PrivateKeyDerivedAccount(key: key, chainType: $0)
            }
        }
    }()
    
    var isMnemonic: Bool { key.isMnemonic }
    
    var name: String { key.name }
    
    init(id: String, key: StoredKey, associatedMetadata: AssociatedMetadata) {
        self.id = id
        self.key = key
        self.associatedMetadata = associatedMetadata
    }
    
    struct DerivedMnemonicAccount: AnyAccount {
        var key: StoredKey
        var chainType: SupportedChainType
        
        var privateKey: PrivateKey? {
            get {
                guard
                    let password = Keychain.shared.password,
                    let privateKey = key.privateKey(
                        coin: chainType.walletCoreCoinType, password: Data(password.utf8)
                    )
                else { return nil }
                return privateKey
            }
        }
        
        var address: String? {
            get {
                guard
                    let password = Keychain.shared.password,
                    let wallet = key.wallet(password: Data(password.utf8)),
                    let account = key.accountForCoin(coin: chainType.walletCoreCoinType, wallet: wallet)
                else { return nil }
                return account.address
            }
        }
        
        // ToDo(@pettrk): Applying formatter
        var privateKeyString: String? { self.privateKey?.data.hexString }
        
        var derivationPath: String? {
            get {
                guard
                    let password = Keychain.shared.password,
                    let wallet = key.wallet(password: Data(password.utf8)),
                    let account = key.accountForCoin(coin: chainType.walletCoreCoinType, wallet: wallet)
                else { return nil  }
                return account.derivationPath
            }
        }
    }
    
    struct PrivateKeyDerivedAccount: AnyAccount {
        var key: StoredKey
        var chainType: SupportedChainType
        
        var privateKey: PrivateKey? {
            get {
                guard
                    let password = Keychain.shared.password,
                    let privateKey = key.decryptPrivateKey(password: Data(password.utf8))
                else { return nil }
                return PrivateKey(data: privateKey)
            }
        }
        
        var address: String? {
            key.accountForCoin(coin: chainType.walletCoreCoinType, wallet: nil)?.address
        }

        var privateKeyString: String? {
            self.privateKey?.data.hexString }
        
        var derivationPath: String? {
            key.accountForCoin(coin: chainType.walletCoreCoinType, wallet: nil)?.address
        }
    }
        
    public subscript<T>(chainType: SupportedChainType, accountDescriptor: AccountDescriptor<T>) -> T? {
        // No throwing keypath available. Nil is sufficient here
        guard
            self.isMnemonic,
            let account = self.accounts.first(where: { $0.chainType == chainType })
        else { return nil }
        return account[keyPath: accountDescriptor.keyPath]
    }
    
    public subscript<T>(accountDescriptor: AccountDescriptor<T>) -> T? {
        guard
            !self.isMnemonic,
            let account = self.accounts.first
        else { return nil }
        return account[keyPath: accountDescriptor.keyPath]
    }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    static func == (lhs: TokenaryWallet, rhs: TokenaryWallet) -> Bool { lhs.id == rhs.id }
    
    struct AccountDescriptor<ReturnType> {
        var keyPath: KeyPath<AnyAccount, ReturnType>
    }
    
    var mnemonic: String {
        get throws {
            guard
                let password = Keychain.shared.password
            else { throw WalletsManager.Error.keychainAccessFailure }
            guard
                let mnemonic = key.decryptMnemonic(password: Data(password.utf8))
            else { throw KeyStore.Error.invalidPassword }
            return mnemonic
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
