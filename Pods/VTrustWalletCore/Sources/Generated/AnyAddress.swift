// SPDX-License-Identifier: Apache-2.0
//
// Copyright © 2017 Trust Wallet.
//
// This is a GENERATED FILE, changes made here WILL BE LOST.
//

import Foundation

/// Represents an address in C++ for almost any blockchain.
public final class AnyAddress: Address {

    /// Compares two addresses for equality.
    ///
    /// - Parameter lhs: The first address to compare.
    /// - Parameter rhs: The second address to compare.
    /// - Returns: bool indicating the addresses are equal.
    public static func == (lhs: AnyAddress, rhs: AnyAddress) -> Bool {
        return TWAnyAddressEqual(lhs.rawValue, rhs.rawValue)
    }

    /// Determines if the string is a valid Any address.
    ///
    /// - Parameter string: address to validate.
    /// - Parameter coin: coin type of the address.
    /// - Returns: bool indicating if the address is valid.
    public static func isValid(string: String, coin: CoinType) -> Bool {
        let stringString = TWStringCreateWithNSString(string)
        defer {
            TWStringDelete(stringString)
        }
        return TWAnyAddressIsValid(stringString, TWCoinType(rawValue: coin.rawValue))
    }

    /// Determines if the string is a valid Any address with the given hrp.
    ///
    /// - Parameter string: address to validate.
    /// - Parameter coin: coin type of the address.
    /// - Parameter hrp: explicit given hrp of the given address.
    /// - Returns: bool indicating if the address is valid.
    public static func isValidBech32(string: String, coin: CoinType, hrp: String) -> Bool {
        let stringString = TWStringCreateWithNSString(string)
        defer {
            TWStringDelete(stringString)
        }
        let hrpString = TWStringCreateWithNSString(hrp)
        defer {
            TWStringDelete(hrpString)
        }
        return TWAnyAddressIsValidBech32(stringString, TWCoinType(rawValue: coin.rawValue), hrpString)
    }

    /// Determines if the string is a valid Any address with the given SS58 network prefix.
    ///
    /// - Parameter string: address to validate.
    /// - Parameter coin: coin type of the address.
    /// - Parameter ss58Prefix: ss58Prefix of the given address.
    /// - Returns: bool indicating if the address is valid.
    public static func isValidSS58(string: String, coin: CoinType, ss58Prefix: UInt32) -> Bool {
        let stringString = TWStringCreateWithNSString(string)
        defer {
            TWStringDelete(stringString)
        }
        return TWAnyAddressIsValidSS58(stringString, TWCoinType(rawValue: coin.rawValue), ss58Prefix)
    }

    /// Returns the address string representation.
    ///
    /// - Parameter address: address to get the string representation of.
    public var description: String {
        return TWStringNSString(TWAnyAddressDescription(rawValue))
    }

    /// Returns coin type of address.
    ///
    /// - Parameter address: address to get the coin type of.
    public var coin: CoinType {
        return CoinType(rawValue: TWAnyAddressCoin(rawValue).rawValue)!
    }

    /// Returns underlaying data (public key or key hash)
    ///
    /// - Parameter address: address to get the data of.
    public var data: Data {
        return TWDataNSData(TWAnyAddressData(rawValue))
    }

    let rawValue: OpaquePointer

    init(rawValue: OpaquePointer) {
        self.rawValue = rawValue
    }

    public init?(string: String, coin: CoinType) {
        let stringString = TWStringCreateWithNSString(string)
        defer {
            TWStringDelete(stringString)
        }
        guard let rawValue = TWAnyAddressCreateWithString(stringString, TWCoinType(rawValue: coin.rawValue)) else {
            return nil
        }
        self.rawValue = rawValue
    }

    public init?(string: String, coin: CoinType, hrp: String) {
        let stringString = TWStringCreateWithNSString(string)
        defer {
            TWStringDelete(stringString)
        }
        let hrpString = TWStringCreateWithNSString(hrp)
        defer {
            TWStringDelete(hrpString)
        }
        guard let rawValue = TWAnyAddressCreateBech32(stringString, TWCoinType(rawValue: coin.rawValue), hrpString) else {
            return nil
        }
        self.rawValue = rawValue
    }

    public init?(string: String, coin: CoinType, ss58Prefix: UInt32) {
        let stringString = TWStringCreateWithNSString(string)
        defer {
            TWStringDelete(stringString)
        }
        guard let rawValue = TWAnyAddressCreateSS58(stringString, TWCoinType(rawValue: coin.rawValue), ss58Prefix) else {
            return nil
        }
        self.rawValue = rawValue
    }

    public init(publicKey: PublicKey, coin: CoinType) {
        rawValue = TWAnyAddressCreateWithPublicKey(publicKey.rawValue, TWCoinType(rawValue: coin.rawValue))
    }

    public init(publicKey: PublicKey, coin: CoinType, derivation: Derivation) {
        rawValue = TWAnyAddressCreateWithPublicKeyDerivation(publicKey.rawValue, TWCoinType(rawValue: coin.rawValue), TWDerivation(rawValue: derivation.rawValue))
    }

    public init(publicKey: PublicKey, coin: CoinType, hrp: String) {
        let hrpString = TWStringCreateWithNSString(hrp)
        defer {
            TWStringDelete(hrpString)
        }
        rawValue = TWAnyAddressCreateBech32WithPublicKey(publicKey.rawValue, TWCoinType(rawValue: coin.rawValue), hrpString)
    }

    public init(publicKey: PublicKey, coin: CoinType, ss58Prefix: UInt32) {
        rawValue = TWAnyAddressCreateSS58WithPublicKey(publicKey.rawValue, TWCoinType(rawValue: coin.rawValue), ss58Prefix)
    }

    public init(publicKey: PublicKey, filecoinAddressType: FilecoinAddressType) {
        rawValue = TWAnyAddressCreateWithPublicKeyFilecoinAddressType(publicKey.rawValue, TWFilecoinAddressType(rawValue: filecoinAddressType.rawValue))
    }

    public init(publicKey: PublicKey, firoAddressType: FiroAddressType) {
        rawValue = TWAnyAddressCreateWithPublicKeyFiroAddressType(publicKey.rawValue, TWFiroAddressType(rawValue: firoAddressType.rawValue))
    }

    deinit {
        TWAnyAddressDelete(rawValue)
    }

}
