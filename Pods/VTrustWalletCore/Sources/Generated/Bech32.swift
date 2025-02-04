// SPDX-License-Identifier: Apache-2.0
//
// Copyright © 2017 Trust Wallet.
//
// This is a GENERATED FILE, changes made here WILL BE LOST.
//

import Foundation

/// Bech32 encode / decode functions
public struct Bech32 {

    /// Encodes data as a Bech32 string.
    ///
    /// - Parameter hrp: The human-readable part.
    /// - Parameter data: The data part.
    /// - Returns: the encoded Bech32 string.
    public static func encode(hrp: String, data: Data) -> String {
        let hrpString = TWStringCreateWithNSString(hrp)
        defer {
            TWStringDelete(hrpString)
        }
        let dataData = TWDataCreateWithNSData(data)
        defer {
            TWDataDelete(dataData)
        }
        return TWStringNSString(TWBech32Encode(hrpString, dataData))
    }

    /// Decodes a Bech32 string. Returns null if the string is not a valid Bech32 string.
    ///
    /// - Parameter string: The Bech32 string to decode.
    /// - Returns: the decoded data, null if the string is not a valid Bech32 string. Note that the human-readable part is not returned.
    public static func decode(string: String) -> Data? {
        let stringString = TWStringCreateWithNSString(string)
        defer {
            TWStringDelete(stringString)
        }
        guard let result = TWBech32Decode(stringString) else {
            return nil
        }
        return TWDataNSData(result)
    }

    /// Encodes data as a Bech32m string.
    ///
    /// - Parameter hrp: The human-readable part.
    /// - Parameter data: The data part.
    /// - Returns: the encoded Bech32m string.
    public static func encodeM(hrp: String, data: Data) -> String {
        let hrpString = TWStringCreateWithNSString(hrp)
        defer {
            TWStringDelete(hrpString)
        }
        let dataData = TWDataCreateWithNSData(data)
        defer {
            TWDataDelete(dataData)
        }
        return TWStringNSString(TWBech32EncodeM(hrpString, dataData))
    }

    /// Decodes a Bech32m string. Returns null if the string is not a valid Bech32m string.
    ///
    /// - Parameter string: The Bech32m string to decode.
    /// - Returns: the decoded data, null if the string is not a valid Bech32m string. Note that the human-readable part is not returned.
    public static func decodeM(string: String) -> Data? {
        let stringString = TWStringCreateWithNSString(string)
        defer {
            TWStringDelete(stringString)
        }
        guard let result = TWBech32DecodeM(stringString) else {
            return nil
        }
        return TWDataNSData(result)
    }


    init() {
    }


}
