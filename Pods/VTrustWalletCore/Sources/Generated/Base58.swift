// SPDX-License-Identifier: Apache-2.0
//
// Copyright © 2017 Trust Wallet.
//
// This is a GENERATED FILE, changes made here WILL BE LOST.
//

import Foundation

/// Base58 encode / decode functions
public struct Base58 {

    /// Encodes data as a Base58 string, including the checksum.
    ///
    /// - Parameter data: The data to encode.
    /// - Returns: the encoded Base58 string with checksum.
    public static func encode(data: Data) -> String {
        let dataData = TWDataCreateWithNSData(data)
        defer {
            TWDataDelete(dataData)
        }
        return TWStringNSString(TWBase58Encode(dataData))
    }

    /// Encodes data as a Base58 string, not including the checksum.
    ///
    /// - Parameter data: The data to encode.
    /// - Returns: then encoded Base58 string without checksum.
    public static func encodeNoCheck(data: Data) -> String {
        let dataData = TWDataCreateWithNSData(data)
        defer {
            TWDataDelete(dataData)
        }
        return TWStringNSString(TWBase58EncodeNoCheck(dataData))
    }

    /// Decodes a Base58 string, checking the checksum. Returns null if the string is not a valid Base58 string.
    ///
    /// - Parameter string: The Base58 string to decode.
    /// - Returns: the decoded data, null if the string is not a valid Base58 string with checksum.
    public static func decode(string: String) -> Data? {
        let stringString = TWStringCreateWithNSString(string)
        defer {
            TWStringDelete(stringString)
        }
        guard let result = TWBase58Decode(stringString) else {
            return nil
        }
        return TWDataNSData(result)
    }

    /// Decodes a Base58 string, w/o checking the checksum. Returns null if the string is not a valid Base58 string.
    ///
    /// - Parameter string: The Base58 string to decode.
    /// - Returns: the decoded data, null if the string is not a valid Base58 string without checksum.
    public static func decodeNoCheck(string: String) -> Data? {
        let stringString = TWStringCreateWithNSString(string)
        defer {
            TWStringDelete(stringString)
        }
        guard let result = TWBase58DecodeNoCheck(stringString) else {
            return nil
        }
        return TWDataNSData(result)
    }


    init() {
    }


}
