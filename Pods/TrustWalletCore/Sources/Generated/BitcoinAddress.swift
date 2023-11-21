// Copyright © 2017-2023 Trust Wallet.
//
// This file is part of Trust. The full Trust copyright notice, including
// terms governing use, modification, and redistribution, is contained in the
// file LICENSE at the root of the source code distribution tree.
//
// This is a GENERATED FILE, changes made here WILL BE LOST.
//

import Foundation

/// Represents a legacy Bitcoin address in C++.
public final class BitcoinAddress: Address {

    /// Compares two addresses for equality.
    ///
    /// - Parameter lhs: The first address to compare.
    /// - Parameter rhs: The second address to compare.
    /// - Returns: bool indicating the addresses are equal.
    public static func == (lhs: BitcoinAddress, rhs: BitcoinAddress) -> Bool {
        return TWBitcoinAddressEqual(lhs.rawValue, rhs.rawValue)
    }

    /// Determines if the data is a valid Bitcoin address.
    ///
    /// - Parameter data: data to validate.
    /// - Returns: bool indicating if the address data is valid.
    public static func isValid(data: Data) -> Bool {
        let dataData = TWDataCreateWithNSData(data)
        defer {
            TWDataDelete(dataData)
        }
        return TWBitcoinAddressIsValid(dataData)
    }

    /// Determines if the string is a valid Bitcoin address.
    ///
    /// - Parameter string: string to validate.
    /// - Returns: bool indicating if the address string is valid.
    public static func isValidString(string: String) -> Bool {
        let stringString = TWStringCreateWithNSString(string)
        defer {
            TWStringDelete(stringString)
        }
        return TWBitcoinAddressIsValidString(stringString)
    }

    /// Returns the address in Base58 string representation.
    ///
    /// - Parameter address: Address to get the string representation of.
    public var description: String {
        return TWStringNSString(TWBitcoinAddressDescription(rawValue))
    }

    /// Returns the address prefix.
    ///
    /// - Parameter address: Address to get the prefix of.
    public var prefix: UInt8 {
        return TWBitcoinAddressPrefix(rawValue)
    }

    /// Returns the key hash data.
    ///
    /// - Parameter address: Address to get the keyhash data of.
    public var keyhash: Data {
        return TWDataNSData(TWBitcoinAddressKeyhash(rawValue))
    }

    let rawValue: OpaquePointer

    init(rawValue: OpaquePointer) {
        self.rawValue = rawValue
    }

    public init?(string: String) {
        let stringString = TWStringCreateWithNSString(string)
        defer {
            TWStringDelete(stringString)
        }
        guard let rawValue = TWBitcoinAddressCreateWithString(stringString) else {
            return nil
        }
        self.rawValue = rawValue
    }

    public init?(data: Data) {
        let dataData = TWDataCreateWithNSData(data)
        defer {
            TWDataDelete(dataData)
        }
        guard let rawValue = TWBitcoinAddressCreateWithData(dataData) else {
            return nil
        }
        self.rawValue = rawValue
    }

    public init?(publicKey: PublicKey, prefix: UInt8) {
        guard let rawValue = TWBitcoinAddressCreateWithPublicKey(publicKey.rawValue, prefix) else {
            return nil
        }
        self.rawValue = rawValue
    }

    deinit {
        TWBitcoinAddressDelete(rawValue)
    }

}
