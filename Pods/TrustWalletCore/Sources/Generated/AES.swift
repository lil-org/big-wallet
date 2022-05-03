// Copyright © 2017-2020 Trust Wallet.
//
// This file is part of Trust. The full Trust copyright notice, including
// terms governing use, modification, and redistribution, is contained in the
// file LICENSE at the root of the source code distribution tree.
//
// This is a GENERATED FILE, changes made here WILL BE LOST.
//

import Foundation

public struct AES {

    public static func encryptCBC(key: Data, data: Data, iv: Data, mode: AESPaddingMode) -> Data? {
        let keyData = TWDataCreateWithNSData(key)
        defer {
            TWDataDelete(keyData)
        }
        let dataData = TWDataCreateWithNSData(data)
        defer {
            TWDataDelete(dataData)
        }
        let ivData = TWDataCreateWithNSData(iv)
        defer {
            TWDataDelete(ivData)
        }
        guard let result = TWAESEncryptCBC(keyData, dataData, ivData, TWAESPaddingMode(rawValue: mode.rawValue)) else {
            return nil
        }
        return TWDataNSData(result)
    }

    public static func decryptCBC(key: Data, data: Data, iv: Data, mode: AESPaddingMode) -> Data? {
        let keyData = TWDataCreateWithNSData(key)
        defer {
            TWDataDelete(keyData)
        }
        let dataData = TWDataCreateWithNSData(data)
        defer {
            TWDataDelete(dataData)
        }
        let ivData = TWDataCreateWithNSData(iv)
        defer {
            TWDataDelete(ivData)
        }
        guard let result = TWAESDecryptCBC(keyData, dataData, ivData, TWAESPaddingMode(rawValue: mode.rawValue)) else {
            return nil
        }
        return TWDataNSData(result)
    }

    public static func encryptCTR(key: Data, data: Data, iv: Data) -> Data? {
        let keyData = TWDataCreateWithNSData(key)
        defer {
            TWDataDelete(keyData)
        }
        let dataData = TWDataCreateWithNSData(data)
        defer {
            TWDataDelete(dataData)
        }
        let ivData = TWDataCreateWithNSData(iv)
        defer {
            TWDataDelete(ivData)
        }
        guard let result = TWAESEncryptCTR(keyData, dataData, ivData) else {
            return nil
        }
        return TWDataNSData(result)
    }

    public static func decryptCTR(key: Data, data: Data, iv: Data) -> Data? {
        let keyData = TWDataCreateWithNSData(key)
        defer {
            TWDataDelete(keyData)
        }
        let dataData = TWDataCreateWithNSData(data)
        defer {
            TWDataDelete(dataData)
        }
        let ivData = TWDataCreateWithNSData(iv)
        defer {
            TWDataDelete(ivData)
        }
        guard let result = TWAESDecryptCTR(keyData, dataData, ivData) else {
            return nil
        }
        return TWDataNSData(result)
    }


    init() {
    }


}
