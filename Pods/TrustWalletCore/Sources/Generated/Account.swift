// SPDX-License-Identifier: Apache-2.0
//
// Copyright © 2017 Trust Wallet.
//
// This is a GENERATED FILE, changes made here WILL BE LOST.
//

import Foundation

/// Represents an Account in C++ with address, coin type and public key info, an item within a keystore.
public final class Account {

    /// Returns the address of an account.
    ///
    /// - Parameter account: Account to get the address of.
    public var address: String {
        return TWStringNSString(TWAccountAddress(rawValue))
    }

    /// Return CoinType enum of an account.
    ///
    /// - Parameter account: Account to get the coin type of.
    public var coin: CoinType {
        return CoinType(rawValue: TWAccountCoin(rawValue).rawValue)!
    }

    /// Returns the derivation enum of an account.
    ///
    /// - Parameter account: Account to get the derivation enum of.
    public var derivation: Derivation {
        return Derivation(rawValue: TWAccountDerivation(rawValue).rawValue)!
    }

    /// Returns derivationPath of an account.
    ///
    /// - Parameter account: Account to get the derivation path of.
    public var derivationPath: String {
        return TWStringNSString(TWAccountDerivationPath(rawValue))
    }

    /// Returns hex encoded publicKey of an account.
    ///
    /// - Parameter account: Account to get the public key of.
    public var publicKey: String {
        return TWStringNSString(TWAccountPublicKey(rawValue))
    }

    /// Returns Base58 encoded extendedPublicKey of an account.
    ///
    /// - Parameter account: Account to get the extended public key of.
    public var extendedPublicKey: String {
        return TWStringNSString(TWAccountExtendedPublicKey(rawValue))
    }

    let rawValue: OpaquePointer

    init(rawValue: OpaquePointer) {
        self.rawValue = rawValue
    }

    public init(address: String, coin: CoinType, derivation: Derivation, derivationPath: String, publicKey: String, extendedPublicKey: String) {
        let addressString = TWStringCreateWithNSString(address)
        defer {
            TWStringDelete(addressString)
        }
        let derivationPathString = TWStringCreateWithNSString(derivationPath)
        defer {
            TWStringDelete(derivationPathString)
        }
        let publicKeyString = TWStringCreateWithNSString(publicKey)
        defer {
            TWStringDelete(publicKeyString)
        }
        let extendedPublicKeyString = TWStringCreateWithNSString(extendedPublicKey)
        defer {
            TWStringDelete(extendedPublicKeyString)
        }
        rawValue = TWAccountCreate(addressString, TWCoinType(rawValue: coin.rawValue), TWDerivation(rawValue: derivation.rawValue), derivationPathString, publicKeyString, extendedPublicKeyString)
    }

    deinit {
        TWAccountDelete(rawValue)
    }

}
