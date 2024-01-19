// SPDX-License-Identifier: Apache-2.0
//
// Copyright © 2017 Trust Wallet.
//
// This is a GENERATED FILE, changes made here WILL BE LOST.
//

import Foundation

/// Base32 encode / decode functions
public struct Base32 {

    /// Decode a Base32 input with the given alphabet
    ///
    /// - Parameter string: Encoded base32 input to be decoded
    /// - Parameter alphabet: Decode with the given alphabet, if nullptr ALPHABET_RFC4648 is used by default
    /// - Returns: The decoded data, can be null.
    /// - Note: ALPHABET_RFC4648 doesn't support padding in the default alphabet
    public static func decodeWithAlphabet(string: String, alphabet: String?) -> Data? {
        let stringString = TWStringCreateWithNSString(string)
        defer {
            TWStringDelete(stringString)
        }
        let alphabetString: UnsafeRawPointer?
        if let s = alphabet {
            alphabetString = TWStringCreateWithNSString(s)
        } else {
            alphabetString = nil
        }
        defer {
            if let s = alphabetString {
                TWStringDelete(s)
            }
        }
        guard let result = TWBase32DecodeWithAlphabet(stringString, alphabetString) else {
            return nil
        }
        return TWDataNSData(result)
    }

    /// Decode a Base32 input with the default alphabet (ALPHABET_RFC4648)
    ///
    /// - Parameter string: Encoded input to be decoded
    /// - Returns: The decoded data
    /// - Note: Call TWBase32DecodeWithAlphabet with nullptr.
    public static func decode(string: String) -> Data? {
        let stringString = TWStringCreateWithNSString(string)
        defer {
            TWStringDelete(stringString)
        }
        guard let result = TWBase32Decode(stringString) else {
            return nil
        }
        return TWDataNSData(result)
    }

    /// Encode an input to Base32 with the given alphabet
    ///
    /// - Parameter data: Data to be encoded (raw bytes)
    /// - Parameter alphabet: Encode with the given alphabet, if nullptr ALPHABET_RFC4648 is used by default
    /// - Returns: The encoded data
    /// - Note: ALPHABET_RFC4648 doesn't support padding in the default alphabet
    public static func encodeWithAlphabet(data: Data, alphabet: String?) -> String {
        let dataData = TWDataCreateWithNSData(data)
        defer {
            TWDataDelete(dataData)
        }
        let alphabetString: UnsafeRawPointer?
        if let s = alphabet {
            alphabetString = TWStringCreateWithNSString(s)
        } else {
            alphabetString = nil
        }
        defer {
            if let s = alphabetString {
                TWStringDelete(s)
            }
        }
        return TWStringNSString(TWBase32EncodeWithAlphabet(dataData, alphabetString))
    }

    /// Encode an input to Base32 with the default alphabet (ALPHABET_RFC4648)
    ///
    /// - Parameter data: Data to be encoded (raw bytes)
    /// - Returns: The encoded data
    /// - Note: Call TWBase32EncodeWithAlphabet with nullptr.
    public static func encode(data: Data) -> String {
        let dataData = TWDataCreateWithNSData(data)
        defer {
            TWDataDelete(dataData)
        }
        return TWStringNSString(TWBase32Encode(dataData))
    }


    init() {
    }


}
