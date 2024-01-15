// SPDX-License-Identifier: Apache-2.0
//
// Copyright © 2017 Trust Wallet.
//
// This is a GENERATED FILE, changes made here WILL BE LOST.
//

import Foundation

/// Represents a Ripple X-address.
public final class RippleXAddress: Address {

    /// Compares two addresses for equality.
    ///
    /// - Parameter lhs: left non-null pointer to a Ripple Address
    /// - Parameter rhs: right non-null pointer to a Ripple Address
    /// - Returns: true if both address are equal, false otherwise
    public static func == (lhs: RippleXAddress, rhs: RippleXAddress) -> Bool {
        return TWRippleXAddressEqual(lhs.rawValue, rhs.rawValue)
    }

    /// Determines if the string is a valid Ripple address.
    ///
    /// - Parameter string: Non-null pointer to a string that represent the Ripple Address to be checked
    /// - Returns: true if the given address is a valid Ripple address, false otherwise
    public static func isValidString(string: String) -> Bool {
        let stringString = TWStringCreateWithNSString(string)
        defer {
            TWStringDelete(stringString)
        }
        return TWRippleXAddressIsValidString(stringString)
    }

    /// Returns the address string representation.
    ///
    /// - Parameter address: Non-null pointer to a Ripple Address
    /// - Returns: Non-null pointer to the ripple address string representation
    public var description: String {
        return TWStringNSString(TWRippleXAddressDescription(rawValue))
    }

    /// Returns the destination tag.
    ///
    /// - Parameter address: Non-null pointer to a Ripple Address
    /// - Returns: The destination tag of the given Ripple Address (1-10)
    public var tag: UInt32 {
        return TWRippleXAddressTag(rawValue)
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
        guard let rawValue = TWRippleXAddressCreateWithString(stringString) else {
            return nil
        }
        self.rawValue = rawValue
    }

    public init(publicKey: PublicKey, tag: UInt32) {
        rawValue = TWRippleXAddressCreateWithPublicKey(publicKey.rawValue, tag)
    }

    deinit {
        TWRippleXAddressDelete(rawValue)
    }

}
