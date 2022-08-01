// Copyright © 2017-2022 Trust Wallet.
//
// This file is part of Trust. The full Trust copyright notice, including
// terms governing use, modification, and redistribution, is contained in the
// file LICENSE at the root of the source code distribution tree.
//
// This is a GENERATED FILE, changes made here WILL BE LOST.
//

import Foundation

public struct Base32 {

    public static func decodeWithAlphabet(string: String, alphabet: String) -> Data? {
        let stringString = TWStringCreateWithNSString(string)
        defer {
            TWStringDelete(stringString)
        }
        let alphabetString = TWStringCreateWithNSString(alphabet)
        defer {
            TWStringDelete(alphabetString)
        }
        guard let result = TWBase32DecodeWithAlphabet(stringString, alphabetString) else {
            return nil
        }
        return TWDataNSData(result)
    }

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

    public static func encodeWithAlphabet(data: Data, alphabet: String) -> String {
        let dataData = TWDataCreateWithNSData(data)
        defer {
            TWDataDelete(dataData)
        }
        let alphabetString = TWStringCreateWithNSString(alphabet)
        defer {
            TWStringDelete(alphabetString)
        }
        return TWStringNSString(TWBase32EncodeWithAlphabet(dataData, alphabetString))
    }

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
