// SPDX-License-Identifier: Apache-2.0
//
// Copyright © 2017 Trust Wallet.
//
// This is a GENERATED FILE, changes made here WILL BE LOST.
//

import Foundation

/// Represents a legacy Groestlcoin address.
public final class GroestlcoinAddress: Address {

    /// Compares two addresses for equality.
    ///
    /// - Parameter lhs: left Non-null GroestlCoin address to be compared
    /// - Parameter rhs: right Non-null GroestlCoin address to be compared
    /// - Returns: true if both address are equal, false otherwise
    public static func == (lhs: GroestlcoinAddress, rhs: GroestlcoinAddress) -> Bool {
        return TWGroestlcoinAddressEqual(lhs.rawValue, rhs.rawValue)
    }

    /// Determines if the string is a valid Groestlcoin address.
    ///
    /// - Parameter string: Non-null string.
    /// - Returns: true if it's a valid address, false otherwise
    public static func isValidString(string: String) -> Bool {
        let stringString = TWStringCreateWithNSString(string)
        defer {
            TWStringDelete(stringString)
        }
        return TWGroestlcoinAddressIsValidString(stringString)
    }

    /// Returns the address base58 string representation.
    ///
    /// - Parameter address: Non-null GroestlcoinAddress
    /// - Returns: Address description as a non-null string
    public var description: String {
        return TWStringNSString(TWGroestlcoinAddressDescription(rawValue))
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
        guard let rawValue = TWGroestlcoinAddressCreateWithString(stringString) else {
            return nil
        }
        self.rawValue = rawValue
    }

    public init(publicKey: PublicKey, prefix: UInt8) {
        rawValue = TWGroestlcoinAddressCreateWithPublicKey(publicKey.rawValue, prefix)
    }

    deinit {
        TWGroestlcoinAddressDelete(rawValue)
    }

}
