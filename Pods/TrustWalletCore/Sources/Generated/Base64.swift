// Copyright © 2017-2023 Trust Wallet.
//
// This file is part of Trust. The full Trust copyright notice, including
// terms governing use, modification, and redistribution, is contained in the
// file LICENSE at the root of the source code distribution tree.
//
// This is a GENERATED FILE, changes made here WILL BE LOST.
//

import Foundation

/// Base64 encode / decode functions
public struct Base64 {

    /// Decode a Base64 input with the default alphabet (RFC4648 with '+', '/')
    ///
    /// - Parameter string: Encoded input to be decoded
    /// - Returns: The decoded data, empty if decoding failed.
    public static func decode(string: String) -> Data? {
        let stringString = TWStringCreateWithNSString(string)
        defer {
            TWStringDelete(stringString)
        }
        guard let result = TWBase64Decode(stringString) else {
            return nil
        }
        return TWDataNSData(result)
    }

    /// Decode a Base64 input with the alphabet safe for URL-s and filenames (RFC4648 with '-', '_')
    ///
    /// - Parameter string: Encoded base64 input to be decoded
    /// - Returns: The decoded data, empty if decoding failed.
    public static func decodeUrl(string: String) -> Data? {
        let stringString = TWStringCreateWithNSString(string)
        defer {
            TWStringDelete(stringString)
        }
        guard let result = TWBase64DecodeUrl(stringString) else {
            return nil
        }
        return TWDataNSData(result)
    }

    /// Encode an input to Base64 with the default alphabet (RFC4648 with '+', '/')
    ///
    /// - Parameter data: Data to be encoded (raw bytes)
    /// - Returns: The encoded data
    public static func encode(data: Data) -> String {
        let dataData = TWDataCreateWithNSData(data)
        defer {
            TWDataDelete(dataData)
        }
        return TWStringNSString(TWBase64Encode(dataData))
    }

    /// Encode an input to Base64 with the alphabet safe for URL-s and filenames (RFC4648 with '-', '_')
    ///
    /// - Parameter data: Data to be encoded (raw bytes)
    /// - Returns: The encoded data
    public static func encodeUrl(data: Data) -> String {
        let dataData = TWDataCreateWithNSData(data)
        defer {
            TWDataDelete(dataData)
        }
        return TWStringNSString(TWBase64EncodeUrl(dataData))
    }


    init() {
    }


}
