// Copyright © 2017-2022 Trust Wallet.
//
// This file is part of Trust. The full Trust copyright notice, including
// terms governing use, modification, and redistribution, is contained in the
// file LICENSE at the root of the source code distribution tree.
//
// This is a GENERATED FILE, changes made here WILL BE LOST.
//

import Foundation

public struct Base64 {

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

    public static func encode(data: Data) -> String {
        let dataData = TWDataCreateWithNSData(data)
        defer {
            TWDataDelete(dataData)
        }
        return TWStringNSString(TWBase64Encode(dataData))
    }

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
