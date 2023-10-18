// Copyright © 2017-2023 Trust Wallet.
//
// This file is part of Trust. The full Trust copyright notice, including
// terms governing use, modification, and redistribution, is contained in the
// file LICENSE at the root of the source code distribution tree.
//
// This is a GENERATED FILE, changes made here WILL BE LOST.
//

import Foundation

/// Hierarchical Deterministic (HD) Wallet
public final class HDWallet {

    /// Computes the public key from an extended public key representation.
    ///
    /// - Parameter extended: extended public key
    /// - Parameter coin: a coin type
    /// - Parameter derivationPath: a derivation path
    /// - Note: Returned object needs to be deleted with \TWPublicKeyDelete
    /// - Returns: Nullable TWPublic key
    public static func getPublicKeyFromExtended(extended: String, coin: CoinType, derivationPath: String) -> PublicKey? {
        let extendedString = TWStringCreateWithNSString(extended)
        defer {
            TWStringDelete(extendedString)
        }
        let derivationPathString = TWStringCreateWithNSString(derivationPath)
        defer {
            TWStringDelete(derivationPathString)
        }
        guard let value = TWHDWalletGetPublicKeyFromExtended(extendedString, TWCoinType(rawValue: coin.rawValue), derivationPathString) else {
            return nil
        }
        return PublicKey(rawValue: value)
    }

    /// Wallet seed.
    ///
    /// - Parameter wallet: non-null TWHDWallet
    /// - Returns: The wallet seed as a Non-null block of data.
    public var seed: Data {
        return TWDataNSData(TWHDWalletSeed(rawValue))
    }

    /// Wallet Mnemonic
    ///
    /// - Parameter wallet: non-null TWHDWallet
    /// - Returns: The wallet mnemonic as a non-null TWString
    public var mnemonic: String {
        return TWStringNSString(TWHDWalletMnemonic(rawValue))
    }

    /// Wallet entropy
    ///
    /// - Parameter wallet: non-null TWHDWallet
    /// - Returns: The wallet entropy as a non-null block of data.
    public var entropy: Data {
        return TWDataNSData(TWHDWalletEntropy(rawValue))
    }

    let rawValue: OpaquePointer

    init(rawValue: OpaquePointer) {
        self.rawValue = rawValue
    }

    public init?(strength: Int32, passphrase: String) {
        let passphraseString = TWStringCreateWithNSString(passphrase)
        defer {
            TWStringDelete(passphraseString)
        }
        guard let rawValue = TWHDWalletCreate(Int32(strength), passphraseString) else {
            return nil
        }
        self.rawValue = rawValue
    }

    public init?(mnemonic: String, passphrase: String) {
        let mnemonicString = TWStringCreateWithNSString(mnemonic)
        defer {
            TWStringDelete(mnemonicString)
        }
        let passphraseString = TWStringCreateWithNSString(passphrase)
        defer {
            TWStringDelete(passphraseString)
        }
        guard let rawValue = TWHDWalletCreateWithMnemonic(mnemonicString, passphraseString) else {
            return nil
        }
        self.rawValue = rawValue
    }

    public init?(mnemonic: String, passphrase: String, check: Bool) {
        let mnemonicString = TWStringCreateWithNSString(mnemonic)
        defer {
            TWStringDelete(mnemonicString)
        }
        let passphraseString = TWStringCreateWithNSString(passphrase)
        defer {
            TWStringDelete(passphraseString)
        }
        guard let rawValue = TWHDWalletCreateWithMnemonicCheck(mnemonicString, passphraseString, check) else {
            return nil
        }
        self.rawValue = rawValue
    }

    public init?(entropy: Data, passphrase: String) {
        let entropyData = TWDataCreateWithNSData(entropy)
        defer {
            TWDataDelete(entropyData)
        }
        let passphraseString = TWStringCreateWithNSString(passphrase)
        defer {
            TWStringDelete(passphraseString)
        }
        guard let rawValue = TWHDWalletCreateWithEntropy(entropyData, passphraseString) else {
            return nil
        }
        self.rawValue = rawValue
    }

    deinit {
        TWHDWalletDelete(rawValue)
    }

    /// Returns master key.
    ///
    /// - Parameter wallet: non-null TWHDWallet
    /// - Parameter curve:  a curve
    /// - Note: Returned object needs to be deleted with \TWPrivateKeyDelete
    /// - Returns: Non-null corresponding private key
    public func getMasterKey(curve: Curve) -> PrivateKey {
        return PrivateKey(rawValue: TWHDWalletGetMasterKey(rawValue, TWCurve(rawValue: curve.rawValue)))
    }

    /// Generates the default private key for the specified coin, using default derivation.
    ///
    /// - SeeAlso: TWHDWalletGetKey
    /// - SeeAlso: TWHDWalletGetKeyDerivation
    /// - Parameter wallet: non-null TWHDWallet
    /// - Parameter coin:  a coin type
    /// - Note: Returned object needs to be deleted with \TWPrivateKeyDelete
    /// - Returns: return the default private key for the specified coin
    public func getKeyForCoin(coin: CoinType) -> PrivateKey {
        return PrivateKey(rawValue: TWHDWalletGetKeyForCoin(rawValue, TWCoinType(rawValue: coin.rawValue)))
    }

    /// Generates the default address for the specified coin (without exposing intermediary private key), default derivation.
    ///
    /// - SeeAlso: TWHDWalletGetAddressDerivation
    /// - Parameter wallet: non-null TWHDWallet
    /// - Parameter coin:  a coin type
    /// - Returns: return the default address for the specified coin as a non-null TWString
    public func getAddressForCoin(coin: CoinType) -> String {
        return TWStringNSString(TWHDWalletGetAddressForCoin(rawValue, TWCoinType(rawValue: coin.rawValue)))
    }

    /// Generates the default address for the specified coin and derivation (without exposing intermediary private key).
    ///
    /// - SeeAlso: TWHDWalletGetAddressForCoin
    /// - Parameter wallet: non-null TWHDWallet
    /// - Parameter coin:  a coin type
    /// - Parameter derivation:  a (custom) derivation to use
    /// - Returns: return the default address for the specified coin as a non-null TWString
    public func getAddressDerivation(coin: CoinType, derivation: Derivation) -> String {
        return TWStringNSString(TWHDWalletGetAddressDerivation(rawValue, TWCoinType(rawValue: coin.rawValue), TWDerivation(rawValue: derivation.rawValue)))
    }

    /// Generates the private key for the specified derivation path.
    ///
    /// - SeeAlso: TWHDWalletGetKeyForCoin
    /// - SeeAlso: TWHDWalletGetKeyDerivation
    /// - Parameter wallet: non-null TWHDWallet
    /// - Parameter coin: a coin type
    /// - Parameter derivationPath:  a non-null derivation path
    /// - Note: Returned object needs to be deleted with \TWPrivateKeyDelete
    /// - Returns: The private key for the specified derivation path/coin
    public func getKey(coin: CoinType, derivationPath: String) -> PrivateKey {
        let derivationPathString = TWStringCreateWithNSString(derivationPath)
        defer {
            TWStringDelete(derivationPathString)
        }
        return PrivateKey(rawValue: TWHDWalletGetKey(rawValue, TWCoinType(rawValue: coin.rawValue), derivationPathString))
    }

    /// Generates the private key for the specified derivation.
    ///
    /// - SeeAlso: TWHDWalletGetKey
    /// - SeeAlso: TWHDWalletGetKeyForCoin
    /// - Parameter wallet: non-null TWHDWallet
    /// - Parameter coin: a coin type
    /// - Parameter derivation: a (custom) derivation to use
    /// - Note: Returned object needs to be deleted with \TWPrivateKeyDelete
    /// - Returns: The private key for the specified derivation path/coin
    public func getKeyDerivation(coin: CoinType, derivation: Derivation) -> PrivateKey {
        return PrivateKey(rawValue: TWHDWalletGetKeyDerivation(rawValue, TWCoinType(rawValue: coin.rawValue), TWDerivation(rawValue: derivation.rawValue)))
    }

    /// Generates the private key for the specified derivation path and curve.
    ///
    /// - Parameter wallet: non-null TWHDWallet
    /// - Parameter curve: a curve
    /// - Parameter derivationPath:  a non-null derivation path
    /// - Note: Returned object needs to be deleted with \TWPrivateKeyDelete
    /// - Returns: The private key for the specified derivation path/curve
    public func getKeyByCurve(curve: Curve, derivationPath: String) -> PrivateKey {
        let derivationPathString = TWStringCreateWithNSString(derivationPath)
        defer {
            TWStringDelete(derivationPathString)
        }
        return PrivateKey(rawValue: TWHDWalletGetKeyByCurve(rawValue, TWCurve(rawValue: curve.rawValue), derivationPathString))
    }

    /// Shortcut method to generate private key with the specified account/change/address (bip44 standard).
    ///
    /// - SeeAlso: https://github.com/bitcoin/bips/blob/master/bip-0044.mediawiki
    ///
    /// - Parameter wallet: non-null TWHDWallet
    /// - Parameter coin: a coin type
    /// - Parameter account: valid bip44 account
    /// - Parameter change: valid bip44 change
    /// - Parameter address: valid bip44 address
    /// - Note: Returned object needs to be deleted with \TWPrivateKeyDelete
    /// - Returns: The private key for the specified bip44 parameters
    public func getDerivedKey(coin: CoinType, account: UInt32, change: UInt32, address: UInt32) -> PrivateKey {
        return PrivateKey(rawValue: TWHDWalletGetDerivedKey(rawValue, TWCoinType(rawValue: coin.rawValue), account, change, address))
    }

    /// Returns the extended private key (for default 0 account).
    ///
    /// - Parameter wallet: non-null TWHDWallet
    /// - Parameter purpose: a purpose
    /// - Parameter coin: a coin type
    /// - Parameter version: hd version
    /// - Note: Returned object needs to be deleted with \TWStringDelete
    /// - Returns:  Extended private key as a non-null TWString
    public func getExtendedPrivateKey(purpose: Purpose, coin: CoinType, version: HDVersion) -> String {
        return TWStringNSString(TWHDWalletGetExtendedPrivateKey(rawValue, TWPurpose(rawValue: purpose.rawValue), TWCoinType(rawValue: coin.rawValue), TWHDVersion(rawValue: version.rawValue)))
    }

    /// Returns the extended public key (for default 0 account).
    ///
    /// - Parameter wallet: non-null TWHDWallet
    /// - Parameter purpose: a purpose
    /// - Parameter coin: a coin type
    /// - Parameter version: hd version
    /// - Note: Returned object needs to be deleted with \TWStringDelete
    /// - Returns:  Extended public key as a non-null TWString
    public func getExtendedPublicKey(purpose: Purpose, coin: CoinType, version: HDVersion) -> String {
        return TWStringNSString(TWHDWalletGetExtendedPublicKey(rawValue, TWPurpose(rawValue: purpose.rawValue), TWCoinType(rawValue: coin.rawValue), TWHDVersion(rawValue: version.rawValue)))
    }

    /// Returns the extended private key, for custom account.
    ///
    /// - Parameter wallet: non-null TWHDWallet
    /// - Parameter purpose: a purpose
    /// - Parameter coin: a coin type
    /// - Parameter derivation: a derivation
    /// - Parameter version: an hd version
    /// - Parameter account: valid bip44 account
    /// - Note: Returned object needs to be deleted with \TWStringDelete
    /// - Returns:  Extended private key as a non-null TWString
    public func getExtendedPrivateKeyAccount(purpose: Purpose, coin: CoinType, derivation: Derivation, version: HDVersion, account: UInt32) -> String {
        return TWStringNSString(TWHDWalletGetExtendedPrivateKeyAccount(rawValue, TWPurpose(rawValue: purpose.rawValue), TWCoinType(rawValue: coin.rawValue), TWDerivation(rawValue: derivation.rawValue), TWHDVersion(rawValue: version.rawValue), account))
    }

    /// Returns the extended public key, for custom account.
    ///
    /// - Parameter wallet: non-null TWHDWallet
    /// - Parameter purpose: a purpose
    /// - Parameter coin: a coin type
    /// - Parameter derivation: a derivation
    /// - Parameter version: an hd version
    /// - Parameter account: valid bip44 account
    /// - Note: Returned object needs to be deleted with \TWStringDelete
    /// - Returns: Extended public key as a non-null TWString
    public func getExtendedPublicKeyAccount(purpose: Purpose, coin: CoinType, derivation: Derivation, version: HDVersion, account: UInt32) -> String {
        return TWStringNSString(TWHDWalletGetExtendedPublicKeyAccount(rawValue, TWPurpose(rawValue: purpose.rawValue), TWCoinType(rawValue: coin.rawValue), TWDerivation(rawValue: derivation.rawValue), TWHDVersion(rawValue: version.rawValue), account))
    }

    /// Returns the extended private key (for default 0 account with derivation).
    ///
    /// - Parameter wallet: non-null TWHDWallet
    /// - Parameter purpose: a purpose
    /// - Parameter coin: a coin type
    /// - Parameter derivation: a derivation
    /// - Parameter version: an hd version
    /// - Note: Returned object needs to be deleted with \TWStringDelete
    /// - Returns:  Extended private key as a non-null TWString
    public func getExtendedPrivateKeyDerivation(purpose: Purpose, coin: CoinType, derivation: Derivation, version: HDVersion) -> String {
        return TWStringNSString(TWHDWalletGetExtendedPrivateKeyDerivation(rawValue, TWPurpose(rawValue: purpose.rawValue), TWCoinType(rawValue: coin.rawValue), TWDerivation(rawValue: derivation.rawValue), TWHDVersion(rawValue: version.rawValue)))
    }

    /// Returns the extended public key (for default 0 account with derivation).
    ///
    /// - Parameter wallet: non-null TWHDWallet
    /// - Parameter purpose: a purpose
    /// - Parameter coin: a coin type
    /// - Parameter derivation: a derivation
    /// - Parameter version: an hd version
    /// - Note: Returned object needs to be deleted with \TWStringDelete
    /// - Returns:  Extended public key as a non-null TWString
    public func getExtendedPublicKeyDerivation(purpose: Purpose, coin: CoinType, derivation: Derivation, version: HDVersion) -> String {
        return TWStringNSString(TWHDWalletGetExtendedPublicKeyDerivation(rawValue, TWPurpose(rawValue: purpose.rawValue), TWCoinType(rawValue: coin.rawValue), TWDerivation(rawValue: derivation.rawValue), TWHDVersion(rawValue: version.rawValue)))
    }

}
