// SPDX-License-Identifier: Apache-2.0
//
// Copyright © 2017 Trust Wallet.
//
// This is a GENERATED FILE, changes made here WILL BE LOST.
//

import Foundation

/// Represents a BIP 0173 address.
public final class SegwitAddress: Address {

    /// Compares two addresses for equality.
    ///
    /// - Parameter lhs: left non-null pointer to a Bech32 Address
    /// - Parameter rhs: right non-null pointer to a Bech32 Address
    /// - Returns: true if both address are equal, false otherwise
    public static func == (lhs: SegwitAddress, rhs: SegwitAddress) -> Bool {
        return TWSegwitAddressEqual(lhs.rawValue, rhs.rawValue)
    }

    /// Determines if the string is a valid Bech32 address.
    ///
    /// - Parameter string: Non-null pointer to a Bech32 address as a string
    /// - Returns: true if the string is a valid Bech32 address, false otherwise.
    public static func isValidString(string: String) -> Bool {
        let stringString = TWStringCreateWithNSString(string)
        defer {
            TWStringDelete(stringString)
        }
        return TWSegwitAddressIsValidString(stringString)
    }

    /// Returns the address string representation.
    ///
    /// - Parameter address: Non-null pointer to a Segwit Address
    /// - Returns: Non-null pointer to the segwit address string representation
    public var description: String {
        return TWStringNSString(TWSegwitAddressDescription(rawValue))
    }

    /// Returns the human-readable part.
    ///
    /// - Parameter address: Non-null pointer to a Segwit Address
    /// - Returns: the HRP part of the given address
    public var hrp: HRP {
        return HRP(rawValue: TWSegwitAddressHRP(rawValue).rawValue)!
    }

    /// Returns the human-readable part.
    ///
    /// - Parameter address: Non-null pointer to a Segwit Address
    /// - Returns: returns the witness version of the given segwit address
    public var witnessVersion: Int32 {
        return TWSegwitAddressWitnessVersion(rawValue)
    }

    /// Returns the witness program
    ///
    /// - Parameter address: Non-null pointer to a Segwit Address
    /// - Returns: returns the witness data of the given segwit address as a non-null pointer block of data
    public var witnessProgram: Data {
        return TWDataNSData(TWSegwitAddressWitnessProgram(rawValue))
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
        guard let rawValue = TWSegwitAddressCreateWithString(stringString) else {
            return nil
        }
        self.rawValue = rawValue
    }

    public init(hrp: HRP, publicKey: PublicKey) {
        rawValue = TWSegwitAddressCreateWithPublicKey(TWHRP(rawValue: hrp.rawValue), publicKey.rawValue)
    }

    deinit {
        TWSegwitAddressDelete(rawValue)
    }

}
