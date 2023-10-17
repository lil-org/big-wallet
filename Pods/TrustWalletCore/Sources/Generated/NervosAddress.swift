// Copyright © 2017-2023 Trust Wallet.
//
// This file is part of Trust. The full Trust copyright notice, including
// terms governing use, modification, and redistribution, is contained in the
// file LICENSE at the root of the source code distribution tree.
//
// This is a GENERATED FILE, changes made here WILL BE LOST.
//

import Foundation

/// Represents a Nervos address.
public final class NervosAddress: Address {

    /// Compares two addresses for equality.
    ///
    /// - Parameter lhs: The first address to compare.
    /// - Parameter rhs: The second address to compare.
    /// - Returns: bool indicating the addresses are equal.
    public static func == (lhs: NervosAddress, rhs: NervosAddress) -> Bool {
        return TWNervosAddressEqual(lhs.rawValue, rhs.rawValue)
    }

    /// Determines if the string is a valid Nervos address.
    ///
    /// - Parameter string: string to validate.
    /// - Returns: bool indicating if the address is valid.
    public static func isValidString(string: String) -> Bool {
        let stringString = TWStringCreateWithNSString(string)
        defer {
            TWStringDelete(stringString)
        }
        return TWNervosAddressIsValidString(stringString)
    }

    /// Returns the address string representation.
    ///
    /// - Parameter address: Address to get the string representation of.
    public var description: String {
        return TWStringNSString(TWNervosAddressDescription(rawValue))
    }

    /// Returns the Code hash
    ///
    /// - Parameter address: Address to get the keyhash data of.
    public var codeHash: Data {
        return TWDataNSData(TWNervosAddressCodeHash(rawValue))
    }

    /// Returns the address hash type
    ///
    /// - Parameter address: Address to get the hash type of.
    public var hashType: String {
        return TWStringNSString(TWNervosAddressHashType(rawValue))
    }

    /// Returns the address args data.
    ///
    /// - Parameter address: Address to get the args data of.
    public var args: Data {
        return TWDataNSData(TWNervosAddressArgs(rawValue))
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
        guard let rawValue = TWNervosAddressCreateWithString(stringString) else {
            return nil
        }
        self.rawValue = rawValue
    }

    deinit {
        TWNervosAddressDelete(rawValue)
    }

}
