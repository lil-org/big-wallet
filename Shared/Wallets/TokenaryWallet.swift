// Copyright © 2021 Tokenary. All rights reserved.
// Rewrite of Wallet.swift from Trust Wallet Core.

import Foundation
import WalletCore

protocol AnyAccount {
    var chainType: SupportedChainType { get }
    
    var privateKey: PrivateKey? { get }
    var address: String? { get }
    var privateKeyString: String? { get }
    var derivationPath: String? { get }
}

public final class TokenaryWallet: Hashable, Equatable {
    public struct AccountDescriptor<ReturnType> {
        var keyPath: KeyPath<AnyAccount, ReturnType>
    }
    
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
        
        internal init(walletDerivationType: WalletDerivationType) {
            self.walletDerivationType = walletDerivationType
        }
        
        public var walletDerivationType: WalletDerivationType
    }
    
    struct DerivedMnemonicAccount: AnyAccount {
        init?(key: StoredKey, chainType: SupportedChainType, address: String?) {
            self.key = key
            self.chainType = chainType
            self.address = address
        }
        
        var key: StoredKey
        var chainType: SupportedChainType
        
        var privateKey: PrivateKey? {
            guard
                let password = Keychain.shared.password,
                let privateKey = key.privateKey(
                    coin: chainType.walletCoreCoinType, password: Data(password.utf8)
                )
            else { return nil }
            return privateKey
        }
        
        let address: String?
        
        // ToDo: Applying formatter
        var privateKeyString: String? { self.privateKey?.data.hexString }
        
        var derivationPath: String? {
            guard
                let password = Keychain.shared.password,
                let wallet = key.wallet(password: Data(password.utf8)),
                let account = key.accountForCoin(coin: chainType.walletCoreCoinType, wallet: wallet)
            else { return nil  }
            return account.derivationPath
        }
    }
    
    struct PrivateKeyDerivedAccount: AnyAccount {
        internal init(key: StoredKey, chainType: SupportedChainType, address: String?) {
            self.key = key
            self.chainType = chainType
            self.address = address
        }
        
        var key: StoredKey
        var chainType: SupportedChainType
        
        var privateKey: PrivateKey? {
            guard
                let password = Keychain.shared.password,
                let privateKey = key.decryptPrivateKey(password: Data(password.utf8))
            else { return nil }
            return PrivateKey(data: privateKey)
        }
        
        let address: String?
        
        var privateKeyString: String? {
            self.privateKey?.data.hexString
        }
        
        var derivationPath: String? {
            key.accountForCoin(coin: chainType.walletCoreCoinType, wallet: nil)?.address
        }
    }

    let id: String
    var key: StoredKey
    var associatedMetadata: AssociatedMetadata {
        didSet {
            self.accounts = self.generateAccounts()
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

    public func hash(into hasher: inout Hasher) { hasher.combine(self.id) }

    public static func == (lhs: TokenaryWallet, rhs: TokenaryWallet) -> Bool { lhs.id == rhs.id }
    
    private func generateAccounts() -> [AnyAccount] {
        if self.isMnemonic {
            guard
                let password = Keychain.shared.password,
                let wallet = key.wallet(password: Data(password.utf8))
            else { return [] }
            return associatedMetadata.walletDerivationType.chainTypes.compactMap {
                let address = key.accountForCoin(coin: $0.walletCoreCoinType, wallet: wallet)?.address
                return DerivedMnemonicAccount(key: key, chainType: $0, address: address)
            }
        } else {
            return associatedMetadata.walletDerivationType.chainTypes.compactMap {
                let address = key.accountForCoin(coin: $0.walletCoreCoinType, wallet: nil)?.address
                return PrivateKeyDerivedAccount(key: key, chainType: $0, address: address)
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
